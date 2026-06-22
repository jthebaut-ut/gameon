import SwiftUI

struct DiscoverSponsoredVenueLocationFields: Equatable, Sendable {
    var city: String?
    var state: String?
}

struct DiscoverSponsoredAnnouncementChipMetadata: Equatable, Sendable {
    var eventDate: Date?
    var venueCity: String?
    var venueState: String?
    var venueAddress: String?
    var venueName: String?
    var venueSecondaryPhotoURL: String?
    var venueSecondaryPhotoThumbnailURL: String?

    static let empty = DiscoverSponsoredAnnouncementChipMetadata()

    func venueLineText(for announcement: FanGeoAnnouncement) -> String {
        let name = venueName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !name.isEmpty { return name }
        if announcement.promotedVenueId != nil { return "" }
        return locationLabel(for: announcement) ?? ""
    }

    func locationLabel(for announcement: FanGeoAnnouncement) -> String? {
        DiscoverSponsoredAnnouncementChipFormatter.locationChipText(
            venueCity: venueCity,
            venueState: venueState,
            venueAddress: venueAddress,
            targetCity: announcement.targetCity,
            targetState: announcement.targetState
        )
    }

    func chips(for announcement: FanGeoAnnouncement, now: Date = Date()) -> [DiscoverSponsoredAnnouncementChip] {
        guard announcement.isSponsoredDiscoverPromotion else { return [] }

        var chips: [DiscoverSponsoredAnnouncementChip] = []
        if let dateText = DiscoverSponsoredAnnouncementChipFormatter.dateChipText(
            eventDate: eventDate,
            promotionStart: announcement.startDate,
            promotionEnd: announcement.endDate,
            now: now
        ) {
            chips.append(.init(kind: .date, text: dateText))
        }
        if let locationText = locationLabel(for: announcement) {
            let hasVenueName = !(venueName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            if hasVenueName || venueLineText(for: announcement) != locationText {
                chips.append(.init(kind: .location, text: locationText))
            }
        }
        if let offerChip = Self.offerChip(for: announcement) {
            chips.append(offerChip)
        }
        return chips
    }

    private static func offerChip(for announcement: FanGeoAnnouncement) -> DiscoverSponsoredAnnouncementChip? {
        let adminOfferText = announcement.trimmedPromoOfferChip
        guard !adminOfferText.isEmpty else { return nil }

        return .init(
            kind: .offer,
            text: adminOfferText,
            symbolIconName: DiscoverSponsoredOfferChipIcon.resolve(
                promoOfferType: announcement.promoOfferType,
                offerText: adminOfferText
            ),
            isPinned: true
        )
    }
}

enum DiscoverSponsoredOfferChipIcon {
    static func resolve(promoOfferType: String?, offerText: String) -> String {
        if let mapped = iconName(forPromoOfferType: promoOfferType) {
            return mapped
        }
        return inferredIconName(from: offerText)
    }

    static func iconName(forPromoOfferType raw: String?) -> String? {
        let key = normalizedPromoOfferTypeKey(raw)
        guard !key.isEmpty else { return nil }

        switch key {
        case "free":
            return "gift.circle.fill"
        case "discount":
            return "tag.circle.fill"
        case "ticketed":
            return "ticket.fill"
        case "food":
            return "fork.knife.circle.fill"
        case "drink":
            return "wineglass.fill"
        case "merchandise":
            return "bag.circle.fill"
        case "vip":
            return "star.circle.fill"
        case "general":
            return "gift.circle.fill"
        default:
            return nil
        }
    }

    private static func inferredIconName(from text: String) -> String {
        let lower = text.lowercased()
        if lower.contains("ticket") || lower.contains("entry") || lower.contains("admission") {
            return "ticket.fill"
        }
        if lower.contains("drink") || lower.contains("cocktail") || lower.contains("beer")
            || lower.contains("wine") || lower.contains("happy hour") {
            return "wineglass.fill"
        }
        if lower.contains("food") || lower.contains("appetizer") || lower.contains("meal")
            || lower.contains("dinner") || lower.contains("lunch") {
            return "fork.knife.circle.fill"
        }
        if lower.contains("%") || lower.contains("off") || lower.contains("discount") || lower.contains("deal") {
            return "tag.circle.fill"
        }
        if lower.contains("vip") {
            return "star.circle.fill"
        }
        if lower.contains("merch") || lower.contains("shirt") || lower.contains("gear") {
            return "bag.circle.fill"
        }
        return "gift.circle.fill"
    }

    private static func normalizedPromoOfferTypeKey(_ raw: String?) -> String {
        raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_") ?? ""
    }
}

struct DiscoverSponsoredAnnouncementChip: Identifiable, Equatable {
    enum Kind: String {
        case date
        case location
        case offer

        var defaultIconName: String {
            switch self {
            case .date: return "calendar.circle.fill"
            case .location: return "mappin.circle.fill"
            case .offer: return "gift.circle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .date: return .blue
            case .location: return .green
            case .offer: return .orange
            }
        }

        func paletteSecondary(for colorScheme: ColorScheme) -> Color {
            tint.opacity(colorScheme == .dark ? 0.46 : 0.40)
        }
    }

    let kind: Kind
    let text: String
    let symbolIconName: String
    let isPinned: Bool

    var id: String { kind.rawValue }

    init(kind: Kind, text: String, symbolIconName: String? = nil, isPinned: Bool = false) {
        self.kind = kind
        self.text = text
        self.symbolIconName = symbolIconName ?? kind.defaultIconName
        self.isPinned = isPinned
    }
}

private enum DiscoverAnnouncementPremiumSymbol {
    static func icon(
        _ name: String,
        tint: Color,
        size: CGFloat,
        weight: Font.Weight = .semibold,
        renderingMode: SymbolRenderingMode = .hierarchical
    ) -> some View {
        Image(systemName: name)
            .font(.system(size: size, weight: weight))
            .symbolRenderingMode(renderingMode)
            .foregroundStyle(tint)
    }

    static func paletteIcon(
        _ name: String,
        primary: Color,
        secondary: Color,
        size: CGFloat,
        weight: Font.Weight = .semibold
    ) -> some View {
        Image(systemName: name)
            .font(.system(size: size, weight: weight))
            .symbolRenderingMode(.palette)
            .foregroundStyle(primary, secondary)
    }
}

enum DiscoverSponsoredAnnouncementChipFormatter {
    private static let hiddenFieldValues: Set<String> = [
        "general announcement",
        "venue promotion"
    ]

    private static let genericPromotionPhrases: Set<String> = [
        "come see us",
        "come visit us",
        "come visit",
        "visit us",
        "see us",
        "join us",
        "special night",
        "check us out",
        "don't miss",
        "don't miss out",
        "happening now",
        "stop by",
        "stop in",
        "we'd love to see you",
        "see you there"
    ]

    private static let offerKeywords: [String] = [
        "free",
        "off",
        "%",
        "deal",
        "special",
        "cocktail",
        "drink",
        "entry",
        "admission",
        "ticket",
        "happy hour",
        "promo",
        "promotion",
        "discount",
        "complimentary",
        "giveaway",
        "2-for-1",
        "two for one",
        "bogo"
    ]

    static func dateChipText(
        eventDate: Date?,
        promotionStart: Date?,
        promotionEnd: Date?,
        now: Date = Date()
    ) -> String? {
        if let eventDate {
            return formatSingleDate(eventDate, now: now)
        }
        return formatPromotionDateRange(start: promotionStart, end: promotionEnd, now: now)
    }

    static func locationChipText(
        venueCity: String?,
        venueState: String?,
        venueAddress: String?,
        targetCity: String?,
        targetState: String?
    ) -> String? {
        let fields = resolveLocationFields(
            venueCity: venueCity,
            venueState: venueState,
            venueAddress: venueAddress,
            targetCity: targetCity,
            targetState: targetState
        )
        return cityStateChipLabel(city: fields.city, state: fields.state)
    }

    static func resolveLocationFields(
        venueCity: String?,
        venueState: String?,
        venueAddress: String?,
        targetCity: String?,
        targetState: String?
    ) -> DiscoverSponsoredVenueLocationFields {
        let scrubbedVenue = scrubVenueLocationInputs(venueCity: venueCity, venueState: venueState)
        if let fields = validCityStateFields(
            city: scrubbedVenue.city,
            state: scrubbedVenue.state
        ) {
            return fields
        }

        let parsed = parseCityStateFromAddress(cleanedField(venueAddress))
        if let fields = validCityStateFields(city: parsed.city, state: parsed.state) {
            return fields
        }

        let scrubbedTarget = scrubVenueLocationInputs(venueCity: targetCity, venueState: targetState)
        if let fields = validCityStateFields(
            city: scrubbedTarget.city,
            state: scrubbedTarget.state
        ) {
            return fields
        }

        return DiscoverSponsoredVenueLocationFields(city: nil, state: nil)
    }

    private static func validCityStateFields(city: String?, state: String?) -> DiscoverSponsoredVenueLocationFields? {
        let cleanedCity = sanitizedCity(city)
        guard let cleanedState = normalizedChipState(state), !cleanedCity.isEmpty else {
            return nil
        }
        return DiscoverSponsoredVenueLocationFields(city: cleanedCity, state: cleanedState)
    }

    private static func scrubVenueLocationInputs(
        venueCity: String?,
        venueState: String?
    ) -> (city: String?, state: String?) {
        var city = cleanedField(venueCity)
        var state = cleanedField(venueState)

        if city.contains(",") {
            let parsed = parseCityStateFromAddress(city)
            if let parsedCity = parsed.city, let parsedState = parsed.state,
               !parsedCity.isEmpty, !parsedState.isEmpty {
                return (parsedCity, parsedState)
            }
            city = ""
        }

        if isCountryLabel(state) || isZipOnlyLabel(state) || isStateZipToken(state) {
            state = ""
        }

        if state.contains(",") {
            let parsed = parseCityStateFromAddress("\(city), \(state)")
            if let parsedCity = parsed.city, let parsedState = parsed.state,
               !parsedCity.isEmpty, !parsedState.isEmpty {
                return (parsedCity, parsedState)
            }
            state = ""
        }

        return (
            city.isEmpty ? nil : city,
            state.isEmpty ? nil : state
        )
    }

    private static func cityStateChipLabel(city: String?, state: String?) -> String? {
        guard let fields = validCityStateFields(city: city, state: state),
              let resolvedCity = fields.city,
              let resolvedState = fields.state else {
            return nil
        }
        return "\(resolvedCity), \(resolvedState)"
    }

    private static let blockedCountryLabels: Set<String> = [
        "united states",
        "united states of america",
        "usa",
        "us",
        "u.s.",
        "u.s.a.",
        "united kingdom",
        "uk",
        "canada"
    ]

    private static func sanitizedCity(_ raw: String?) -> String {
        let cleaned = cleanedField(raw)
        guard !cleaned.isEmpty else { return "" }
        guard !isCountryLabel(cleaned) else { return "" }
        guard !isZipOnlyLabel(cleaned) else { return "" }
        guard !isStateZipToken(cleaned) else { return "" }
        guard !looksLikeStreetAddress(cleaned) else { return "" }
        let upper = cleaned.uppercased()
        if upper.count == 2, upper.allSatisfy(\.isLetter),
           USStatesForBusinessLocation.validCodes.contains(upper) {
            return ""
        }
        return cleaned
    }

    private static func normalizedChipState(_ raw: String?) -> String? {
        let cleaned = cleanedField(raw)
        guard !cleaned.isEmpty else { return nil }
        guard !isCountryLabel(cleaned) else { return nil }
        guard !isZipOnlyLabel(cleaned) else { return nil }

        if let extracted = extractStateFromToken(cleaned),
           USStatesForBusinessLocation.validCodes.contains(extracted) {
            return extracted
        }

        let upper = cleaned.uppercased()
        if upper.count == 2, upper.allSatisfy(\.isLetter),
           USStatesForBusinessLocation.validCodes.contains(upper) {
            return upper
        }

        let lower = cleaned.lowercased()
        if let match = USStatesForBusinessLocation.abbreviationsSortedByName.first(where: {
            $0.1.lowercased() == lower
        }) {
            return match.0
        }

        return nil
    }

    private static func isZipOnlyLabel(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.range(of: #"^\d{5}(-\d{4})?$"#, options: .regularExpression) != nil
    }

    private static func isCountryLabel(_ raw: String) -> Bool {
        blockedCountryLabels.contains(raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    private static func isStateZipToken(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^[A-Za-z]{2}\s+\d{5}(-\d{4})?$"#
        return trimmed.range(of: pattern, options: .regularExpression) != nil
    }

    private static func looksLikeStreetAddress(_ raw: String) -> Bool {
        guard let first = raw.trimmingCharacters(in: .whitespacesAndNewlines).first else { return false }
        return first.isNumber
    }

    private static func extractStateFromToken(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.allSatisfy({ $0.isNumber || $0 == "-" }) { return nil }

        let firstToken = trimmed
            .split(separator: " ")
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !firstToken.isEmpty else { return nil }

        if firstToken.count == 2, firstToken.allSatisfy(\.isLetter) {
            return firstToken.uppercased()
        }
        if firstToken.count <= 3, firstToken.allSatisfy(\.isLetter) {
            return firstToken.uppercased()
        }
        return nil
    }

    private static func parseCityStateFromAddress(_ address: String) -> DiscoverSponsoredVenueLocationFields {
        var parts = address
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        while let last = parts.last, isCountryLabel(last) {
            parts.removeLast()
        }

        guard parts.count >= 2 else {
            if let only = parts.first {
                if let state = extractStateFromToken(only),
                   USStatesForBusinessLocation.validCodes.contains(state) {
                    return DiscoverSponsoredVenueLocationFields(city: nil, state: state)
                }
            }
            return DiscoverSponsoredVenueLocationFields(city: nil, state: nil)
        }

        let lastPart = parts[parts.count - 1]
        guard let state = extractStateFromToken(lastPart),
              USStatesForBusinessLocation.validCodes.contains(state) else {
            return DiscoverSponsoredVenueLocationFields(city: nil, state: nil)
        }

        for index in stride(from: parts.count - 2, through: 0, by: -1) {
            let city = sanitizedCity(parts[index])
            if !city.isEmpty {
                return DiscoverSponsoredVenueLocationFields(city: city, state: state)
            }
        }

        return DiscoverSponsoredVenueLocationFields(city: nil, state: nil)
    }

    static func offerChipText(
        title: String,
        subtitle: String,
        description: String
    ) -> String? {
        let normalizedTitle = cleanedField(title).lowercased()
        let candidates = [cleanedField(description), cleanedField(subtitle)]
            .filter { !$0.isEmpty }
            .filter { !isVenueActionLabel($0) }
            .filter { !isGenericPromotionCopy($0) }
            .filter { cleanedField($0).lowercased() != normalizedTitle }

        let keywordMatches = candidates.filter { containsOfferKeyword($0.lowercased()) }
        if let best = keywordMatches.max(by: { $0.count < $1.count }) {
            return best
        }
        return candidates.max(by: { $0.count < $1.count })
    }

    static func compactCardOfferChipText(_ raw: String, maxLength: Int = 24) -> String {
        let cleaned = cleanedField(raw)
        guard !cleaned.isEmpty else { return "" }
        guard cleaned.count > maxLength else { return cleaned }

        var assembled = ""
        for word in cleaned.split(separator: " ") {
            let token = String(word)
            let candidate = assembled.isEmpty ? token : "\(assembled) \(token)"
            if candidate.count > maxLength {
                break
            }
            assembled = candidate
        }
        if !assembled.isEmpty {
            return assembled
        }

        return String(cleaned.prefix(maxLength))
    }

    static func aggressiveCardOfferChipText(_ raw: String) -> String {
        let cleaned = cleanedField(raw)
        guard !cleaned.isEmpty else { return "" }
        let lower = cleaned.lowercased()

        if lower.contains("vip") {
            return "VIP"
        }
        if let percentRange = cleaned.range(of: #"\d+\s*%"#, options: .regularExpression) {
            let percent = cleaned[percentRange]
                .replacingOccurrences(of: " ", with: "")
            return "\(percent) Off"
        }
        if lower.hasPrefix("free") || (lower.contains("free") && (lower.contains("fangeo") || lower.contains("user"))) {
            return "Free"
        }
        if lower.contains("discount") || lower.contains("off") {
            if let percentRange = cleaned.range(of: #"\d+\s*%"#, options: .regularExpression) {
                let percent = cleaned[percentRange].replacingOccurrences(of: " ", with: "")
                return "\(percent) Off"
            }
        }

        if let firstWord = cleaned.split(separator: " ").first {
            let word = String(firstWord)
            if word.count <= 10 {
                return word
            }
        }

        return compactCardOfferChipText(cleaned, maxLength: 10)
    }

    static func cityOnlyLocationChipText(_ cityState: String) -> String {
        let trimmed = cityState.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let commaIndex = trimmed.firstIndex(of: ",") else { return trimmed }
        return String(trimmed[..<commaIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func abbreviatedCityStateLocationChipText(_ cityState: String) -> String {
        let trimmed = cityState.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let commaIndex = trimmed.firstIndex(of: ",") else { return trimmed }
        let city = String(trimmed[..<commaIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        let state = String(trimmed[trimmed.index(after: commaIndex)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let abbreviatedCity = abbreviateCityNameForChip(city)
        guard !state.isEmpty else { return abbreviatedCity }
        return "\(abbreviatedCity), \(state)"
    }

    private static func abbreviateCityNameForChip(_ city: String) -> String {
        let words = city.split(separator: " ").filter { !$0.isEmpty }
        if words.count >= 2 {
            return words.compactMap(\.first).map { String($0).uppercased() }.joined()
        }
        if city.count > 4 {
            return String(city.prefix(3))
        }
        return city
    }

    fileprivate static func chipDisplayText(
        for chip: DiscoverSponsoredAnnouncementChip,
        locationTier: DiscoverSponsoredChipTextTier,
        offerTier: DiscoverSponsoredChipTextTier
    ) -> String {
        switch chip.kind {
        case .date:
            return chip.text
        case .location:
            switch locationTier {
            case .full:
                return chip.text
            case .compact:
                return cityOnlyLocationChipText(chip.text)
            case .minimal:
                return abbreviatedCityStateLocationChipText(chip.text)
            }
        case .offer:
            switch offerTier {
            case .full:
                return chip.text.count <= 18 ? chip.text : compactCardOfferChipText(chip.text)
            case .compact:
                return compactCardOfferChipText(chip.text)
            case .minimal:
                return aggressiveCardOfferChipText(chip.text)
            }
        }
    }

    static func isSubstantivePromotionCopy(_ text: String) -> Bool {
        let cleaned = cleanedField(text)
        guard !cleaned.isEmpty else { return false }
        guard !isVenueActionLabel(cleaned) else { return false }
        guard !isGenericPromotionCopy(cleaned) else { return false }
        return true
    }

    private static func isVenueActionLabel(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let blockedLabels = [
            "view venue",
            "open venue",
            "visit venue",
            "see venue",
            "go to venue"
        ]
        return blockedLabels.contains(normalized)
    }

    private static func isGenericPromotionCopy(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return true }
        if hiddenFieldValues.contains(normalized) { return true }
        if genericPromotionPhrases.contains(normalized) { return true }
        if normalized.count < 10, !containsOfferKeyword(normalized) { return true }
        return false
    }

    private static func containsOfferKeyword(_ text: String) -> Bool {
        offerKeywords.contains { text.contains($0) }
    }

    private static func cleanedField(_ raw: String?) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return "" }
        guard !hiddenFieldValues.contains(trimmed.lowercased()) else { return "" }
        return trimmed
    }

    private static func formatPromotionDateRange(
        start: Date?,
        end: Date?,
        now: Date
    ) -> String? {
        guard let resolvedStart = start ?? end else { return nil }
        let resolvedEnd = end ?? start ?? resolvedStart
        let calendar = Calendar.current
        if calendar.isDate(resolvedStart, inSameDayAs: resolvedEnd) {
            return formatSingleDate(resolvedStart, now: now)
        }

        let startText = resolvedStart.formatted(.dateTime.month(.abbreviated).day())
        let endText = resolvedEnd.formatted(.dateTime.month(.abbreviated).day())
        if calendar.component(.month, from: resolvedStart) == calendar.component(.month, from: resolvedEnd) {
            let startDay = resolvedStart.formatted(.dateTime.month(.abbreviated).day())
            let endDayOnly = resolvedEnd.formatted(.dateTime.day())
            return "\(startDay)–\(endDayOnly)"
        }
        return "\(startText)–\(endText)"
    }

    private static func formatSingleDate(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            let hour = calendar.component(.hour, from: date)
            return hour >= 17 ? "Tonight" : "Today"
        }
        if calendar.isDateInTomorrow(date) {
            return "Tomorrow"
        }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}

struct DiscoverAnnouncementBannerCarouselView: View {
    let announcements: [FanGeoAnnouncement]
    var isDiscoverTabVisible: Bool = true
    var chipMetadata: (FanGeoAnnouncement) -> DiscoverSponsoredAnnouncementChipMetadata = { _ in .empty }
    var onDismiss: (FanGeoAnnouncement) -> Void
    var onCTA: (FanGeoAnnouncement) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedIndex = 0
    @State private var autoSlideTask: Task<Void, Never>?
    @State private var resumeAutoSlideTask: Task<Void, Never>?
    @State private var isAutoSlidePausedByUser = false
    @State private var isAnnouncementDetailSheetPresented = false
    @State private var isProgrammaticCarouselAdvance = false

    private enum AutoSlideTiming {
        static let advanceNanoseconds: UInt64 = 6_000_000_000
        static let resumeAfterInteractionNanoseconds: UInt64 = 10_000_000_000
        static let advanceAnimation = Animation.easeInOut(duration: 0.35)
    }

    private var announcementIDs: [UUID] {
        announcements.map(\.id)
    }

    private var canAutoSlide: Bool {
        announcements.count > 1
            && isDiscoverTabVisible
            && scenePhase == .active
            && !isAutoSlidePausedByUser
            && !isAnnouncementDetailSheetPresented
    }

    private static let carouselFooterSpacing: CGFloat = 1
    private static let carouselHorizontalPadding: CGFloat = 10
    private static let carouselTopPadding: CGFloat = 4
    private static let carouselBottomPadding: CGFloat = 1
    private static let tabViewHeight: CGFloat = DiscoverAnnouncementBannerPageView.fixedPageHeight

    var body: some View {
        VStack(alignment: .leading, spacing: Self.carouselFooterSpacing) {
            TabView(selection: $selectedIndex) {
                ForEach(Array(announcements.enumerated()), id: \.element.id) { index, announcement in
                    DiscoverAnnouncementBannerPageView(
                        announcement: announcement,
                        chipMetadata: chipMetadata(announcement),
                        onDismiss: {
                            pauseAutoSlideForUserInteraction()
                            onDismiss(announcement)
                        },
                        onCTA: {
                            pauseAutoSlideForUserInteraction()
                            onCTA(announcement)
                        },
                        onDetailSheetPresented: pauseAutoSlideForDetailSheetPresentation,
                        onDetailSheetDismissed: handleDetailSheetDismissed
                    )
                    .frame(maxWidth: .infinity, minHeight: Self.tabViewHeight, maxHeight: Self.tabViewHeight, alignment: .topLeading)
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: Self.tabViewHeight)

            if announcements.count > 1 {
                HStack(spacing: 8) {
                    announcementPageDots
                    Spacer(minLength: 0)
                    Text("\(selectedIndex + 1) of \(announcements.count)")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
        }
        .padding(.horizontal, Self.carouselHorizontalPadding)
        .padding(.top, Self.carouselTopPadding)
        .padding(.bottom, Self.carouselBottomPadding)
        .background { discoverAnnouncementBannerCardBackground }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(SettingsPremiumChrome.cardStroke(colorScheme), lineWidth: 0.75)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.20 : 0.08), radius: 10, y: 4)
        .accessibilityElement(children: .contain)
        .onChange(of: announcementIDs) { _, _ in
            clampSelectedIndexAfterAnnouncementChange()
            syncAutoSlide()
        }
        .onChange(of: selectedIndex) { _, _ in
            handleCarouselSelectionChange()
        }
        .onChange(of: isDiscoverTabVisible) { _, _ in
            syncAutoSlide()
        }
        .onChange(of: scenePhase) { _, _ in
            syncAutoSlide()
        }
        .onChange(of: isAnnouncementDetailSheetPresented) { _, _ in
            syncAutoSlide()
        }
        .onAppear {
            clampSelectedIndexAfterAnnouncementChange()
            syncAutoSlide()
        }
        .onDisappear {
            stopAllAutoSlideTasks()
            isAutoSlidePausedByUser = false
            isAnnouncementDetailSheetPresented = false
        }
    }

    private var announcementPageDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<announcements.count, id: \.self) { index in
                Circle()
                    .fill(index == selectedIndex ? FGColor.accentBlue : Color.clear)
                    .overlay {
                        Circle()
                            .strokeBorder(
                                FGColor.mutedText(colorScheme).opacity(index == selectedIndex ? 0 : 0.55),
                                lineWidth: 1
                            )
                    }
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel("Announcement \(selectedIndex + 1) of \(announcements.count)")
    }

    @ViewBuilder
    private var discoverAnnouncementBannerCardBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(SettingsPremiumChrome.cardFill(colorScheme))
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            SettingsPremiumChrome.cardHighlight(colorScheme),
                            Color.clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
    }

    private func clampSelectedIndexAfterAnnouncementChange() {
        guard !announcements.isEmpty else {
            if selectedIndex != 0 {
                isProgrammaticCarouselAdvance = true
                selectedIndex = 0
            }
            return
        }
        if selectedIndex >= announcements.count {
            isProgrammaticCarouselAdvance = true
            selectedIndex = announcements.count - 1
        } else if selectedIndex < 0 {
            isProgrammaticCarouselAdvance = true
            selectedIndex = 0
        }
    }

    private func syncAutoSlide() {
        stopAutoSlide()
        guard canAutoSlide else { return }

        autoSlideTask = Task { @MainActor in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: AutoSlideTiming.advanceNanoseconds)
                } catch {
                    break
                }
                guard !Task.isCancelled, canAutoSlide else { break }
                advanceCarouselToNextAnnouncement()
            }
        }
    }

    private func advanceCarouselToNextAnnouncement() {
        guard announcements.count > 1 else { return }
        isProgrammaticCarouselAdvance = true
        withAnimation(AutoSlideTiming.advanceAnimation) {
            selectedIndex = (selectedIndex + 1) % announcements.count
        }
    }

    private func pauseAutoSlideForUserInteraction() {
        guard announcements.count > 1 else { return }
        isAutoSlidePausedByUser = true
        stopAutoSlide()
        stopResumeAutoSlideTask()
        scheduleAutoSlideResume(afterInteraction: true)
    }

    private func pauseAutoSlideForDetailSheetPresentation() {
        guard announcements.count > 1 else { return }
        isAnnouncementDetailSheetPresented = true
        isAutoSlidePausedByUser = true
        stopAutoSlide()
        stopResumeAutoSlideTask()
    }

    private func handleDetailSheetDismissed() {
        guard announcements.count > 1 else {
            isAnnouncementDetailSheetPresented = false
            return
        }
        isAnnouncementDetailSheetPresented = false
        isAutoSlidePausedByUser = true
        stopAutoSlide()
        stopResumeAutoSlideTask()
        scheduleAutoSlideResume(afterInteraction: true)
    }

    private func scheduleAutoSlideResume(afterInteraction: Bool) {
        guard afterInteraction else { return }
        resumeAutoSlideTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: AutoSlideTiming.resumeAfterInteractionNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard !isAnnouncementDetailSheetPresented else { return }
            isAutoSlidePausedByUser = false
            syncAutoSlide()
        }
    }

    private func handleCarouselSelectionChange() {
        if isProgrammaticCarouselAdvance {
            isProgrammaticCarouselAdvance = false
            return
        }
        pauseAutoSlideForUserInteraction()
    }

    private func stopAutoSlide() {
        autoSlideTask?.cancel()
        autoSlideTask = nil
    }

    private func stopResumeAutoSlideTask() {
        resumeAutoSlideTask?.cancel()
        resumeAutoSlideTask = nil
    }

    private func stopAllAutoSlideTasks() {
        stopAutoSlide()
        stopResumeAutoSlideTask()
    }
}

struct DiscoverAnnouncementBannerPageView: View {
    let announcement: FanGeoAnnouncement
    var chipMetadata: DiscoverSponsoredAnnouncementChipMetadata = .empty
    var onDismiss: () -> Void
    var onCTA: () -> Void
    var onDetailSheetPresented: (() -> Void)? = nil
    var onDetailSheetDismissed: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme

    static let fixedPageHeight: CGFloat = 150

    private static let contentRowSpacing: CGFloat = 6
    private static let contentStackSpacing: CGFloat = 2
    private static let sponsoredGoldTint = Color(red: 0.79, green: 0.60, blue: 0.14)
    private static let compactButtonHorizontalPadding: CGFloat = 10
    private static let compactButtonVerticalPadding: CGFloat = 6
    private static let sponsoredCTAButtonVerticalPadding: CGFloat = 5
    private static let compactButtonCornerRadius: CGFloat = 9
    private static let dismissButtonReservedTrailingSpace: CGFloat = 30

    private static let leadingImageSize: CGFloat = 94
    private static let leadingImageCornerRadius: CGFloat = 12
    private static let officialLogoAssetName = "FanGeoAnnouncementLogo"
    private static let officialPreviewLineLimit = 2
    private static let officialMoreLinkCharacterThreshold = 120

    private static let sponsoredImageSize: CGFloat = leadingImageSize
    private static let sponsoredImageCornerRadius: CGFloat = leadingImageCornerRadius
    private static let sponsoredPlaceholderIconSize: CGFloat = 30

    private static let officialTitleFontSize: CGFloat = 17
    private static let sponsoredTitleFontSize: CGFloat = 16
    private static let sponsoredVenueFontSize: CGFloat = 12
    private static let sponsoredVenueIconSize: CGFloat = 11
    private static let cardDescriptionFontSize: CGFloat = 14
    private static let badgeFontSize: CGFloat = 13
    private static let badgeHorizontalPadding: CGFloat = 8
    private static let badgeVerticalPadding: CGFloat = 4
    private static let officialBadgeIconSize: CGFloat = 11
    private static let sponsoredBadgeIconSize: CGFloat = 12.5

    private static let sponsoredContentMaxHeight: CGFloat = fixedPageHeight
    private static let sponsoredDescriptionLineLimit = 2

    @State private var showOfficialDetailSheet = false
    @State private var showSponsoredDetailSheet = false

    private var sponsoredInfoChips: [DiscoverSponsoredAnnouncementChip] {
        chipMetadata.chips(for: announcement)
    }

    private var hasCTA: Bool {
        announcement.shouldShowDiscoverBannerCTA
    }

    var body: some View {
        Group {
            if announcement.isSponsoredDiscoverPromotion {
                sponsoredCompactLayout
            } else {
                officialCompactLayout
            }
        }
        .frame(height: Self.fixedPageHeight, alignment: .top)
        .padding(.trailing, Self.dismissButtonReservedTrailingSpace)
        .overlay(alignment: .topTrailing) {
            dismissButton
        }
        .sheet(isPresented: $showOfficialDetailSheet, onDismiss: {
            onDetailSheetDismissed?()
        }) {
            FanGeoOfficialAnnouncementDetailSheet(
                announcement: announcement,
                onClose: { showOfficialDetailSheet = false },
                onCTA: {
                    showOfficialDetailSheet = false
                    onCTA()
                }
            )
        }
        .sheet(isPresented: $showSponsoredDetailSheet, onDismiss: {
            onDetailSheetDismissed?()
        }) {
            DiscoverSponsoredAnnouncementDetailSheet(
                announcement: announcement,
                chipMetadata: chipMetadata,
                onClose: { showSponsoredDetailSheet = false },
                onCTA: {
                    showSponsoredDetailSheet = false
                    onCTA()
                }
            )
        }
    }

    private var sponsoredVenueLineText: String {
        chipMetadata.venueLineText(for: announcement)
    }

    private var sponsoredDescriptionText: String {
        if !userVisibleDescription.isEmpty { return userVisibleDescription }
        return userVisibleSubtitle
    }

    private var sponsoredCompactLayout: some View {
        HStack(alignment: .top, spacing: Self.contentRowSpacing) {
            sponsoredAnnouncementLeadingImage
                .fixedSize(horizontal: true, vertical: true)
                .layoutPriority(10)

            VStack(alignment: .leading, spacing: Self.contentStackSpacing) {
                sponsoredTypeBadge

                if !userVisibleTitle.isEmpty {
                    Text(userVisibleTitle)
                        .font(.system(size: Self.sponsoredTitleFontSize, weight: .semibold, design: .rounded))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(2)
                        .layoutPriority(4)
                }

                sponsoredVenueLine

                sponsoredDescriptionBody

                if !sponsoredInfoChips.isEmpty {
                    DiscoverSponsoredAnnouncementChipRow(chips: sponsoredInfoChips)
                        .layoutPriority(0)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: Self.sponsoredContentMaxHeight, alignment: .topLeading)
            .layoutPriority(1)

            if hasCTA {
                compactSponsoredCTAButton
                    .frame(maxHeight: Self.sponsoredContentMaxHeight, alignment: .center)
                    .layoutPriority(10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var sponsoredVenueLine: some View {
        let text = sponsoredVenueLineText
        if !text.isEmpty {
            HStack(spacing: 4) {
                DiscoverAnnouncementPremiumSymbol.icon(
                    "building.2.fill",
                    tint: FGColor.secondaryText(colorScheme),
                    size: Self.sponsoredVenueIconSize,
                    weight: .semibold,
                    renderingMode: .hierarchical
                )

                Text(text)
                    .font(.system(size: Self.sponsoredVenueFontSize, weight: .medium, design: .rounded))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(3)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Venue, \(text)")
        }
    }

    private var sponsoredDescriptionBody: some View {
        VStack(alignment: .leading, spacing: 1) {
            let text = sponsoredDescriptionText
            if !text.isEmpty {
                ViewThatFits(in: .vertical) {
                    sponsoredDescriptionTextView(text, lineLimit: Self.sponsoredDescriptionLineLimit)
                    sponsoredDescriptionTextView(text, lineLimit: 1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                onDetailSheetPresented?()
                showSponsoredDetailSheet = true
            } label: {
                Text("More")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(FGColor.accentBlue)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Read full promotion details")
        }
        .layoutPriority(2)
    }

    private func sponsoredDescriptionTextView(_ text: String, lineLimit: Int) -> some View {
        Text(text)
            .font(.system(size: Self.cardDescriptionFontSize, weight: .regular, design: .rounded))
            .foregroundStyle(FGColor.secondaryText(colorScheme))
            .lineLimit(lineLimit)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var officialCompactLayout: some View {
        HStack(alignment: .top, spacing: Self.contentRowSpacing) {
            officialAnnouncementLeadingImage

            VStack(alignment: .leading, spacing: Self.contentStackSpacing) {
                officialTypeBadge

                if !userVisibleTitle.isEmpty {
                    Text(userVisibleTitle)
                        .font(.system(size: Self.officialTitleFontSize, weight: .semibold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(2)
                }

                officialMessageBody

                officialFooterDetail
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                guard officialShowsMoreLink else { return }
                onDetailSheetPresented?()
                showOfficialDetailSheet = true
            }

            if hasCTA {
                compactOfficialCTAButton
                    .frame(maxHeight: Self.fixedPageHeight, alignment: .center)
            } else {
                compactOfficialOKButton
                    .frame(maxHeight: Self.fixedPageHeight, alignment: .center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var officialPreviewMessage: String {
        if !userVisibleDescription.isEmpty { return userVisibleDescription }
        return userVisibleSubtitle
    }

    private var officialShowsMoreLink: Bool {
        guard !announcement.isSponsoredDiscoverPromotion else { return false }
        let preview = officialPreviewMessage
        guard !preview.isEmpty else { return false }
        let hasBothFields = !userVisibleSubtitle.isEmpty && !userVisibleDescription.isEmpty
        return hasBothFields || preview.count > Self.officialMoreLinkCharacterThreshold
    }

    @ViewBuilder
    private var officialMessageBody: some View {
        let preview = officialPreviewMessage

        if !preview.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                Text(preview)
                    .font(.system(size: Self.cardDescriptionFontSize, weight: .regular))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .lineLimit(Self.officialPreviewLineLimit)
                    .truncationMode(.tail)
                    .lineSpacing(0)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if officialShowsMoreLink {
                    Button {
                        onDetailSheetPresented?()
                        showOfficialDetailSheet = true
                    } label: {
                        Text("More")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(FGColor.accentBlue)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Read full announcement")
                }
            }
        }
    }

    private var officialFooterDetail: some View {
        VStack(alignment: .leading, spacing: 1) {
            Rectangle()
                .fill(FGColor.accentBlue)
                .frame(height: 1)
                .frame(maxWidth: .infinity)

            HStack(spacing: 4) {
                DiscoverAnnouncementPremiumSymbol.icon(
                    "megaphone.fill",
                    tint: FGColor.accentBlue,
                    size: 9,
                    weight: .semibold
                )

                Text(Self.officialFooterLabel(for: announcement.createdAt))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(FGColor.accentBlue)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
        .padding(.top, 1)
    }

    static func officialFooterLabel(for createdAt: Date?, now: Date = Date()) -> String {
        let prefix = "FanGeo Update • "
        guard let createdAt else { return prefix + "Today" }

        let calendar = Calendar.current
        let createdDay = calendar.startOfDay(for: createdAt)
        let today = calendar.startOfDay(for: now)
        let dayCount = calendar.dateComponents([.day], from: createdDay, to: today).day ?? 0

        switch dayCount {
        case ..<0:
            return prefix + "Today"
        case 0:
            return prefix + "Today"
        case 1:
            return prefix + "Yesterday"
        case 2...6:
            return prefix + "\(dayCount) days ago"
        default:
            let formatter = DateFormatter()
            formatter.locale = Locale.current
            formatter.dateFormat = "MMM d, yyyy"
            return prefix + formatter.string(from: createdAt)
        }
    }

    private var compactOfficialOKButton: some View {
        Button(action: onDismiss) {
            Text("OK")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(FGColor.accentBlue)
                .padding(.horizontal, Self.compactButtonHorizontalPadding)
                .padding(.vertical, Self.compactButtonVerticalPadding)
                .background(
                    RoundedRectangle(cornerRadius: Self.compactButtonCornerRadius, style: .continuous)
                        .fill(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.16 : 0.08))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: Self.compactButtonCornerRadius, style: .continuous)
                        .strokeBorder(FGColor.accentBlue.opacity(0.38), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dismiss announcement")
    }

    private var compactOfficialCTAButton: some View {
        Button(action: onCTA) {
            Text(announcement.trimmedCTALabel)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, Self.compactButtonHorizontalPadding)
                .padding(.vertical, Self.compactButtonVerticalPadding)
                .background(
                    RoundedRectangle(cornerRadius: Self.compactButtonCornerRadius, style: .continuous)
                        .fill(FGColor.accentBlue)
                )
        }
        .buttonStyle(.plain)
    }

    private var compactSponsoredCTAButton: some View {
        Button(action: onCTA) {
            HStack(spacing: 3) {
                Text(announcement.trimmedCTALabel)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
            }
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, Self.compactButtonHorizontalPadding)
            .padding(.vertical, Self.sponsoredCTAButtonVerticalPadding)
            .background(
                RoundedRectangle(cornerRadius: Self.compactButtonCornerRadius, style: .continuous)
                    .fill(FGColor.accentGreen)
            )
            .shadow(color: FGColor.accentGreen.opacity(colorScheme == .dark ? 0.35 : 0.22), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var dismissButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(FGColor.mutedText(colorScheme))
                .frame(width: 26, height: 26)
                .background(
                    Circle()
                        .fill(SettingsPremiumChrome.iconSurface(colorScheme))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dismiss announcement")
    }

    private var officialTypeBadge: some View {
        HStack(spacing: 4) {
            DiscoverAnnouncementPremiumSymbol.paletteIcon(
                "checkmark.seal.fill",
                primary: FGColor.accentBlue,
                secondary: FGColor.accentBlue.opacity(colorScheme == .dark ? 0.46 : 0.40),
                size: Self.officialBadgeIconSize
            )
            Text("FanGeo Official")
                .font(.system(size: Self.badgeFontSize, weight: .semibold, design: .rounded))
                .foregroundStyle(FGColor.accentBlue)
        }
        .padding(.horizontal, Self.badgeHorizontalPadding)
        .padding(.vertical, Self.badgeVerticalPadding)
        .frame(height: 24)
        .background(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.24 : 0.18))
        .clipShape(Capsule(style: .continuous))
    }

    private var sponsoredTypeBadge: some View {
        HStack(spacing: 4) {
            DiscoverAnnouncementPremiumSymbol.paletteIcon(
                "sparkles.circle.fill",
                primary: Self.sponsoredGoldTint,
                secondary: Self.sponsoredGoldTint.opacity(0.5),
                size: Self.sponsoredBadgeIconSize
            )
            Text("Sponsored")
                .font(.system(size: Self.badgeFontSize, weight: .semibold, design: .rounded))
                .foregroundStyle(Self.sponsoredGoldTint)
        }
        .padding(.horizontal, Self.badgeHorizontalPadding)
        .padding(.vertical, Self.badgeVerticalPadding)
        .frame(height: 24)
        .background(Self.sponsoredGoldTint.opacity(colorScheme == .dark ? 0.22 : 0.16))
        .clipShape(Capsule(style: .continuous))
    }

    private var userVisibleTitle: String {
        Self.userVisibleField(from: announcement.trimmedTitle)
    }

    private var userVisibleSubtitle: String {
        Self.userVisibleField(from: announcement.trimmedSubtitle)
    }

    private var userVisibleDescription: String {
        Self.userVisibleField(from: announcement.trimmedDescription)
    }

    private static func userVisibleField(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        switch trimmed.lowercased() {
        case "general announcement", "venue promotion":
            return ""
        default:
            return trimmed
        }
    }

    @ViewBuilder
    private var officialAnnouncementLeadingImage: some View {
        officialAnnouncementLogoImage
    }

    @ViewBuilder
    private var sponsoredAnnouncementLeadingImage: some View {
        if let imageURL = announcement.resolvedImageURL {
            remoteSponsoredAnnouncementImage(url: imageURL)
        } else {
            sponsoredVenuePlaceholderImage
                .frame(width: Self.sponsoredImageSize, height: Self.sponsoredImageSize)
                .background(sponsoredAnnouncementImageBackground)
                .clipShape(sponsoredAnnouncementImageShape)
                .accessibilityHidden(true)
        }
    }

    private var officialAnnouncementLogoImage: some View {
        officialAnnouncementLogoImageContent
            .frame(width: Self.leadingImageSize, height: Self.leadingImageSize)
            .background(officialAnnouncementImageBackground)
            .clipShape(officialAnnouncementImageShape)
            .accessibilityHidden(true)
    }

    private var officialAnnouncementLogoImageContent: some View {
        Image(Self.officialLogoAssetName)
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .scaledToFit()
            .frame(width: Self.leadingImageSize, height: Self.leadingImageSize)
    }

    @ViewBuilder
    private func remoteSponsoredAnnouncementImage(url: URL) -> some View {
        let shape = sponsoredAnnouncementImageShape

        AsyncImage(url: url, transaction: Transaction(animation: nil)) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            case .failure:
                sponsoredVenuePlaceholderImage
            default:
                sponsoredVenuePlaceholderImage
                    .opacity(0.72)
            }
        }
        .frame(width: Self.sponsoredImageSize, height: Self.sponsoredImageSize)
        .background(sponsoredAnnouncementImageBackground)
        .clipShape(shape)
        .accessibilityLabel("Venue photo")
    }

    private var sponsoredVenuePlaceholderImage: some View {
        DiscoverAnnouncementPremiumSymbol.paletteIcon(
            "storefront.fill",
            primary: Self.sponsoredGoldTint,
            secondary: Self.sponsoredGoldTint.opacity(0.45),
            size: Self.sponsoredPlaceholderIconSize,
            weight: .semibold
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var officialAnnouncementImageShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Self.leadingImageCornerRadius, style: .continuous)
    }

    private var sponsoredAnnouncementImageShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Self.leadingImageCornerRadius, style: .continuous)
    }

    private var officialAnnouncementImageBackground: some View {
        officialAnnouncementImageShape
            .fill(Color.white)
    }

    private var sponsoredAnnouncementImageBackground: some View {
        sponsoredAnnouncementImageShape
            .fill(SettingsPremiumChrome.iconSurface(colorScheme))
    }
}

fileprivate enum DiscoverSponsoredChipTextTier {
    case full
    case compact
    case minimal
}

fileprivate enum DiscoverSponsoredChipStyleTier {
    case standard
    case compact
    case tight

    var iconSize: CGFloat {
        switch self {
        case .standard: return 14
        case .compact: return 13
        case .tight: return 12
        }
    }

    var textSize: CGFloat {
        switch self {
        case .standard: return 10.5
        case .compact: return 10
        case .tight: return 9.5
        }
    }

    var iconTextSpacing: CGFloat {
        switch self {
        case .standard: return 5
        case .compact, .tight: return 4
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .standard: return 8
        case .compact: return 7
        case .tight: return 6
        }
    }

    var verticalPadding: CGFloat {
        switch self {
        case .standard, .compact: return 4
        case .tight: return 3
        }
    }

    var rowSpacing: CGFloat {
        switch self {
        case .standard: return 6
        case .compact: return 5
        case .tight: return 4
        }
    }
}

private struct DiscoverSponsoredChipRowItem: Identifiable {
    let chip: DiscoverSponsoredAnnouncementChip
    let displayText: String

    var id: String { chip.id }
}

private struct DiscoverSponsoredAnnouncementChipRow: View {
    let chips: [DiscoverSponsoredAnnouncementChip]

    private var orderedChips: [DiscoverSponsoredAnnouncementChip] {
        let date = chips.first { $0.kind == .date }
        let location = chips.first { $0.kind == .location }
        let offer = chips.first { $0.kind == .offer }
        return [date, location, offer].compactMap { $0 }
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            chipRow(style: .standard, locationTier: .full, offerTier: .full, wrapped: false)
            chipRow(style: .standard, locationTier: .full, offerTier: .compact, wrapped: false)
            chipRow(style: .standard, locationTier: .full, offerTier: .minimal, wrapped: false)
            chipRow(style: .standard, locationTier: .compact, offerTier: .minimal, wrapped: false)
            chipRow(style: .standard, locationTier: .minimal, offerTier: .minimal, wrapped: false)
            chipRow(style: .compact, locationTier: .minimal, offerTier: .minimal, wrapped: true)
            chipRow(style: .tight, locationTier: .minimal, offerTier: .minimal, wrapped: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Promotion details")
    }

    private func rowItems(
        locationTier: DiscoverSponsoredChipTextTier,
        offerTier: DiscoverSponsoredChipTextTier
    ) -> [DiscoverSponsoredChipRowItem] {
        orderedChips.map { chip in
            DiscoverSponsoredChipRowItem(
                chip: chip,
                displayText: DiscoverSponsoredAnnouncementChipFormatter.chipDisplayText(
                    for: chip,
                    locationTier: chip.kind == .location ? locationTier : .full,
                    offerTier: chip.kind == .offer ? offerTier : .full
                )
            )
        }
    }

    @ViewBuilder
    private func chipRow(
        style: DiscoverSponsoredChipStyleTier,
        locationTier: DiscoverSponsoredChipTextTier,
        offerTier: DiscoverSponsoredChipTextTier,
        wrapped: Bool
    ) -> some View {
        let items = rowItems(locationTier: locationTier, offerTier: offerTier)

        if wrapped {
            DiscoverSponsoredAnnouncementChipFlowLayout(
                horizontalSpacing: style.rowSpacing,
                verticalSpacing: 4
            ) {
                ForEach(items) { item in
                    DiscoverSponsoredAnnouncementChipView(
                        chip: item.chip,
                        displayText: item.displayText,
                        styleTier: style
                    )
                }
            }
        } else {
            HStack(spacing: style.rowSpacing) {
                ForEach(items) { item in
                    DiscoverSponsoredAnnouncementChipView(
                        chip: item.chip,
                        displayText: item.displayText,
                        styleTier: style
                    )
                }
            }
        }
    }
}

private struct DiscoverSponsoredAnnouncementChipFlowLayout: Layout {
    var horizontalSpacing: CGFloat
    var verticalSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }

        let maxWidth = proposal.width ?? .infinity
        if maxWidth.isFinite, maxWidth > 0 {
            let rows = arrangedRows(maxWidth: maxWidth, subviews: subviews)
            let width = min(
                rows.map { rowWidth(for: $0, subviews: subviews) }.max() ?? 0,
                maxWidth
            )
            let rowHeight = tallestChipHeight(in: subviews)
            let height = rowHeight * CGFloat(rows.count)
                + verticalSpacing * CGFloat(max(0, rows.count - 1))
            return CGSize(width: width, height: height)
        }

        let width = rowWidth(for: Array(subviews.indices), subviews: subviews)
        return CGSize(width: width, height: tallestChipHeight(in: subviews))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }

        let rows = arrangedRows(maxWidth: bounds.width, subviews: subviews)
        let rowHeight = tallestChipHeight(in: subviews)
        var y = bounds.minY

        for row in rows {
            var x = bounds.minX
            for index in row {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (rowHeight - size.height) / 2),
                    proposal: ProposedViewSize(width: size.width, height: size.height)
                )
                x += size.width + horizontalSpacing
            }
            y += rowHeight + verticalSpacing
        }
    }

    private func arrangedRows(maxWidth: CGFloat, subviews: Subviews) -> [[Int]] {
        var rows: [[Int]] = [[]]
        var currentRowWidth: CGFloat = 0

        for index in subviews.indices {
            let chipWidth = subviews[index].sizeThatFits(.unspecified).width
            let spacing = rows[rows.count - 1].isEmpty ? 0 : horizontalSpacing
            let nextWidth = currentRowWidth + spacing + chipWidth

            if nextWidth > maxWidth + 0.5, !rows[rows.count - 1].isEmpty {
                rows.append([])
                currentRowWidth = 0
            }

            let addedSpacing = rows[rows.count - 1].isEmpty ? 0 : horizontalSpacing
            currentRowWidth += addedSpacing + chipWidth
            rows[rows.count - 1].append(index)
        }

        return rows
    }

    private func rowWidth(for indices: [Int], subviews: Subviews) -> CGFloat {
        guard !indices.isEmpty else { return 0 }
        let widths = indices.map { subviews[$0].sizeThatFits(.unspecified).width }
        return widths.reduce(0, +) + horizontalSpacing * CGFloat(indices.count - 1)
    }

    private func tallestChipHeight(in subviews: Subviews) -> CGFloat {
        subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
    }
}

private struct DiscoverSponsoredAnnouncementChipView: View {
    let chip: DiscoverSponsoredAnnouncementChip
    let displayText: String
    var styleTier: DiscoverSponsoredChipStyleTier = .standard

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: styleTier.iconTextSpacing) {
            Image(systemName: chip.symbolIconName)
                .font(.system(size: styleTier.iconSize, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(chip.kind.tint, chip.kind.paletteSecondary(for: colorScheme))
                .fixedSize()

            Text(displayText)
                .font(.system(size: styleTier.textSize, weight: .semibold, design: .rounded))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, styleTier.horizontalPadding)
        .padding(.vertical, styleTier.verticalPadding)
        .fixedSize(horizontal: true, vertical: false)
        .background(
            Capsule(style: .continuous)
                .fill(chip.kind.tint.opacity(colorScheme == .dark ? 0.16 : 0.12))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        switch chip.kind {
        case .date:
            return "Date, \(chip.text)"
        case .location:
            return "Location, \(chip.text)"
        case .offer:
            return "Offer, \(chip.text)"
        }
    }
}

private struct DiscoverSponsoredAnnouncementMoreSheetMedia: Equatable {
    let secondaryImageURL: URL?

    init(chipMetadata: DiscoverSponsoredAnnouncementChipMetadata) {
        secondaryImageURL = Self.resolvedVenueSecondaryImageURL(from: chipMetadata)
    }

    private static func resolvedVenueSecondaryImageURL(
        from chipMetadata: DiscoverSponsoredAnnouncementChipMetadata
    ) -> URL? {
        guard let displayURL = ImageDisplayURL.forDetail(
            thumbnail: chipMetadata.venueSecondaryPhotoThumbnailURL,
            full: chipMetadata.venueSecondaryPhotoURL
        ), let url = URL(string: displayURL) else {
            return nil
        }
        return url
    }
}

private struct DiscoverSponsoredPromotionDetailItem: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let symbolName: String?

    init(id: String, title: String, detail: String, symbolName: String? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.symbolName = symbolName
    }
}

private struct DiscoverSponsoredPromotionDetailsSection: View {
    let items: [DiscoverSponsoredPromotionDetailItem]

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Promotion Details")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .textCase(.uppercase)
                    .tracking(0.4)

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                if let symbolName = item.symbolName {
                                    DiscoverAnnouncementPremiumSymbol.icon(
                                        symbolName,
                                        tint: FGColor.accentBlue,
                                        size: 12,
                                        weight: .semibold
                                    )
                                }
                                Text(item.title)
                                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                                    .foregroundStyle(FGColor.primaryText(colorScheme))
                            }

                            Text(item.detail)
                                .font(.system(size: 14, weight: .regular, design: .rounded))
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(SettingsPremiumChrome.cardFill(colorScheme))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(SettingsPremiumChrome.cardStroke(colorScheme), lineWidth: 0.5)
                )
            }
        }
    }
}

private struct DiscoverSponsoredAnnouncementDetailSheet: View {
    let announcement: FanGeoAnnouncement
    let chipMetadata: DiscoverSponsoredAnnouncementChipMetadata
    let onClose: () -> Void
    let onCTA: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Namespace private var venueSecondaryImageZoomNamespace
    @State private var showExpandedSecondaryMedia = false

    private static let heroHeight: CGFloat = 200
    private static let heroCornerRadius: CGFloat = 16
    private static let venueSecondaryImageHeight: CGFloat = 200
    private static let sponsoredGoldTint = Color(red: 0.79, green: 0.60, blue: 0.14)

    private var sheetMedia: DiscoverSponsoredAnnouncementMoreSheetMedia {
        DiscoverSponsoredAnnouncementMoreSheetMedia(chipMetadata: chipMetadata)
    }

    private var userVisibleTitle: String {
        Self.userVisibleField(from: announcement.trimmedTitle)
    }

    private var userVisibleSubtitle: String {
        Self.userVisibleField(from: announcement.trimmedSubtitle)
    }

    private var userVisibleDescription: String {
        Self.userVisibleField(from: announcement.trimmedDescription)
    }

    private var venueName: String {
        chipMetadata.venueLineText(for: announcement)
    }

    private var cityStateLocation: String? {
        chipMetadata.locationLabel(for: announcement)
    }

    private var fullDescriptionText: String {
        let subtitle = userVisibleSubtitle
        let description = userVisibleDescription
        if !description.isEmpty, !subtitle.isEmpty, subtitle != description {
            return "\(subtitle)\n\n\(description)"
        }
        if !description.isEmpty { return description }
        return subtitle
    }

    private var promotionDetailItems: [DiscoverSponsoredPromotionDetailItem] {
        Self.promotionDetailItems(for: announcement, chipMetadata: chipMetadata)
    }

    private var infoChips: [DiscoverSponsoredAnnouncementChip] {
        chipMetadata.chips(for: announcement)
    }

    private var hasCTA: Bool {
        announcement.shouldShowDiscoverBannerCTA
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    sponsoredDetailHeroImage
                        .padding(.bottom, 20)

                    VStack(alignment: .leading, spacing: 18) {
                        sponsoredDetailBadge

                        if !userVisibleTitle.isEmpty {
                            Text(userVisibleTitle)
                                .font(.system(size: 24, weight: .bold, design: .rounded))
                                .foregroundStyle(FGColor.primaryText(colorScheme))
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        sponsoredVenueIdentityBlock

                        if !fullDescriptionText.isEmpty {
                            Text(fullDescriptionText)
                                .font(.system(size: 16, weight: .regular, design: .rounded))
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                                .lineSpacing(4)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        DiscoverSponsoredPromotionDetailsSection(items: promotionDetailItems)

                        sponsoredAdditionalMediaSection

                        if !infoChips.isEmpty {
                            DiscoverSponsoredAnnouncementChipFlowLayout(horizontalSpacing: 7, verticalSpacing: 6) {
                                ForEach(infoChips) { chip in
                                    DiscoverSponsoredAnnouncementChipView(
                                        chip: chip,
                                        displayText: chip.text,
                                        styleTier: .standard
                                    )
                                }
                            }
                        }

                        if hasCTA {
                            Button(action: onCTA) {
                                Text(announcement.trimmedCTALabel)
                                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                                    .background(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .fill(FGColor.accentGreen)
                                    )
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 4)
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .padding(.top, 8)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .fanGeoScreenBackground()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(FGColor.mutedText(colorScheme))
                            .frame(width: 32, height: 32)
                            .background(
                                Circle()
                                    .fill(SettingsPremiumChrome.iconSurface(colorScheme))
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .fullScreenCover(isPresented: $showExpandedSecondaryMedia) {
            if let imageURL = sheetMedia.secondaryImageURL {
                FanGeoZoomableImageFullscreenViewer(
                    source: .remoteURL(imageURL),
                    onDismiss: { showExpandedSecondaryMedia = false }
                )
                .navigationTransition(
                    .zoom(
                        sourceID: Self.venueSecondaryImageZoomTransitionID,
                        in: venueSecondaryImageZoomNamespace
                    )
                )
            }
        }
    }

    private static let venueSecondaryImageZoomTransitionID = "discover-sponsored-venue-secondary-image"

    @ViewBuilder
    private var sponsoredAdditionalMediaSection: some View {
        if let imageURL = sheetMedia.secondaryImageURL {
            VStack(alignment: .leading, spacing: 12) {
                Text("More From This Venue")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .textCase(.uppercase)
                    .tracking(0.4)

                Button {
                    showExpandedSecondaryMedia = true
                } label: {
                    DiscoverCachedRemoteImage(url: imageURL, contentMode: .fill) {
                        Rectangle()
                            .fill(SettingsPremiumChrome.iconSurface(colorScheme))
                            .opacity(colorScheme == .dark ? 0.72 : 0.88)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: Self.venueSecondaryImageHeight)
                    .clipShape(
                        RoundedRectangle(cornerRadius: Self.heroCornerRadius, style: .continuous)
                    )
                    .contentShape(
                        RoundedRectangle(cornerRadius: Self.heroCornerRadius, style: .continuous)
                    )
                    .matchedTransitionSource(
                        id: Self.venueSecondaryImageZoomTransitionID,
                        in: venueSecondaryImageZoomNamespace
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("More from this venue image")
                .accessibilityHint("Opens a fullscreen zoomable view")
            }
        }
    }

    @ViewBuilder
    private var sponsoredDetailHeroImage: some View {
        let shape = RoundedRectangle(cornerRadius: Self.heroCornerRadius, style: .continuous)

        Group {
            if let imageURL = announcement.resolvedImageURL {
                AsyncImage(url: imageURL, transaction: Transaction(animation: nil)) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .interpolation(.high)
                            .scaledToFill()
                    case .failure:
                        sponsoredDetailPlaceholderImage
                    default:
                        sponsoredDetailPlaceholderImage
                            .opacity(0.72)
                    }
                }
            } else {
                sponsoredDetailPlaceholderImage
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.heroHeight)
        .background(shape.fill(SettingsPremiumChrome.iconSurface(colorScheme)))
        .clipShape(shape)
        .contentShape(shape)
        .padding(.horizontal, 20)
        .accessibilityLabel("Venue photo")
    }

    @ViewBuilder
    private var sponsoredVenueIdentityBlock: some View {
        if !venueName.isEmpty || cityStateLocation != nil {
            VStack(alignment: .leading, spacing: 8) {
                if !venueName.isEmpty {
                    HStack(spacing: 6) {
                        DiscoverAnnouncementPremiumSymbol.icon(
                            "building.2.fill",
                            tint: FGColor.secondaryText(colorScheme),
                            size: 14,
                            weight: .semibold,
                            renderingMode: .hierarchical
                        )
                        Text(venueName)
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Venue, \(venueName)")
                }

                if let cityStateLocation {
                    HStack(spacing: 6) {
                        DiscoverAnnouncementPremiumSymbol.paletteIcon(
                            "mappin.circle.fill",
                            primary: .green,
                            secondary: .green.opacity(colorScheme == .dark ? 0.46 : 0.40),
                            size: 15
                        )
                        Text(cityStateLocation)
                            .font(.system(size: 16, weight: .medium, design: .rounded))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Location, \(cityStateLocation)")
                }
            }
        }
    }

    private var sponsoredDetailPlaceholderImage: some View {
        DiscoverAnnouncementPremiumSymbol.paletteIcon(
            "storefront.fill",
            primary: Self.sponsoredGoldTint,
            secondary: Self.sponsoredGoldTint.opacity(0.45),
            size: 52,
            weight: .semibold
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sponsoredDetailBadge: some View {
        HStack(spacing: 4) {
            DiscoverAnnouncementPremiumSymbol.paletteIcon(
                "sparkles.circle.fill",
                primary: Self.sponsoredGoldTint,
                secondary: Self.sponsoredGoldTint.opacity(0.5),
                size: 12
            )
            Text("Sponsored")
                .font(FGTypography.metadata)
                .foregroundStyle(Self.sponsoredGoldTint)
        }
        .padding(.horizontal, FGSpacing.sm + 2)
        .padding(.vertical, FGSpacing.xs + 2)
        .background(Self.sponsoredGoldTint.opacity(colorScheme == .dark ? 0.22 : 0.16))
        .clipShape(Capsule(style: .continuous))
    }

    private static func promotionDetailItems(
        for announcement: FanGeoAnnouncement,
        chipMetadata: DiscoverSponsoredAnnouncementChipMetadata
    ) -> [DiscoverSponsoredPromotionDetailItem] {
        // Reserved for QR codes, promo codes, redeem instructions, VIP access, schedules, and more.
        return []
    }

    private static func userVisibleField(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        switch trimmed.lowercased() {
        case "general announcement", "venue promotion":
            return ""
        default:
            return trimmed
        }
    }
}

private struct DiscoverPromotionalMediaFullscreenView: View {
    let imageURL: URL
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            DiscoverCachedRemoteImage(url: imageURL, contentMode: .fit) {
                ProgressView()
                    .tint(.white)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 24)

            VStack {
                HStack {
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white.opacity(0.92))
                            .frame(width: 36, height: 36)
                            .background(
                                Circle()
                                    .fill(Color.white.opacity(0.16))
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                Spacer()
            }
        }
    }
}

private struct FanGeoOfficialAnnouncementDetailSheet: View {
    let announcement: FanGeoAnnouncement
    let onClose: () -> Void
    let onCTA: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private static let logoAssetName = "FanGeoAnnouncementLogo"
    private static let logoSize: CGFloat = 72
    private static let logoCornerRadius: CGFloat = 12

    private var userVisibleTitle: String {
        Self.userVisibleField(from: announcement.trimmedTitle)
    }

    private var userVisibleSubtitle: String {
        Self.userVisibleField(from: announcement.trimmedSubtitle)
    }

    private var userVisibleDescription: String {
        Self.userVisibleField(from: announcement.trimmedDescription)
    }

    private var displayTitle: String {
        userVisibleTitle.uppercased(with: Locale.current)
    }

    private var hasCTA: Bool {
        announcement.shouldShowDiscoverBannerCTA
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(Self.logoAssetName)
                            .resizable()
                            .interpolation(.high)
                            .antialiased(true)
                            .scaledToFit()
                            .frame(width: Self.logoSize, height: Self.logoSize)
                            .background(
                                RoundedRectangle(cornerRadius: Self.logoCornerRadius, style: .continuous)
                                    .fill(Color.white)
                            )
                            .clipShape(
                                RoundedRectangle(cornerRadius: Self.logoCornerRadius, style: .continuous)
                            )
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 4) {
                                DiscoverAnnouncementPremiumSymbol.icon(
                                    "checkmark.seal.fill",
                                    tint: FGColor.accentBlue,
                                    size: 12,
                                    weight: .semibold
                                )
                                Text("FanGeo Official")
                                    .font(FGTypography.metadata)
                                    .foregroundStyle(FGColor.accentBlue)
                            }
                            .padding(.horizontal, FGSpacing.sm + 2)
                            .padding(.vertical, FGSpacing.xs + 2)
                            .background(FGColor.accentBlue.opacity(0.12))
                            .clipShape(Capsule(style: .continuous))

                            if !userVisibleTitle.isEmpty {
                                Text(displayTitle)
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundStyle(FGColor.primaryText(colorScheme))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if !userVisibleSubtitle.isEmpty {
                        Text(userVisibleSubtitle)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !userVisibleDescription.isEmpty {
                        Text(userVisibleDescription)
                            .font(.system(size: 15, weight: .regular))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 6) {
                        DiscoverAnnouncementPremiumSymbol.icon(
                            "megaphone.fill",
                            tint: FGColor.accentBlue,
                            size: 11,
                            weight: .semibold
                        )
                        Text(DiscoverAnnouncementBannerPageView.officialFooterLabel(for: announcement.createdAt))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(FGColor.accentBlue)
                    }
                    .padding(.top, 4)

                    if hasCTA {
                        Button(action: onCTA) {
                            Text(announcement.trimmedCTALabel)
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(FGColor.accentBlue)
                                )
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .fanGeoScreenBackground()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(FGColor.mutedText(colorScheme))
                            .frame(width: 32, height: 32)
                            .background(
                                Circle()
                                    .fill(SettingsPremiumChrome.iconSurface(colorScheme))
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private static func userVisibleField(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        switch trimmed.lowercased() {
        case "general announcement", "venue promotion":
            return ""
        default:
            return trimmed
        }
    }
}
