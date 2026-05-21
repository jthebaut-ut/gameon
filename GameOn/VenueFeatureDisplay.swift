import SwiftUI

enum VenueFeatureAvailability: Equatable {
    case available
    case unavailable
    case unknown
}

struct VenueFeatureDefinition: Identifiable {
    let id: String
    let iconName: String
    let label: String
    let tint: Color
}

enum VenueFeatureDefinitions {
    static let screens = VenueFeatureDefinition(id: "screens", iconName: "display", label: "Screens", tint: FGColor.accentBlue)
    static let foodDrinks = VenueFeatureDefinition(id: "food_drinks", iconName: "fork.knife", label: "Food / Drinks", tint: FGColor.accentGreen)
    static let wifi = VenueFeatureDefinition(id: "wifi", iconName: "wifi", label: "WiFi", tint: FGColor.accentBlue)
    static let patio = VenueFeatureDefinition(id: "patio", iconName: "sun.max", label: "Terrace", tint: FGColor.businessGreen)
    static let projector = VenueFeatureDefinition(id: "projector", iconName: "video.fill", label: "Projector", tint: FGColor.gradientMiddle)
    static let petFriendly = VenueFeatureDefinition(id: "pet_friendly", iconName: "pawprint.fill", label: "Pet Friendly", tint: FGColor.businessGreen)
    static let parkingAvailable = VenueFeatureDefinition(id: "parking_available", iconName: "car.fill", label: "Parking Available", tint: FGColor.accentYellow)
    static let easyParking = VenueFeatureDefinition(id: "easy_parking", iconName: "parkingsign.circle.fill", label: "Easy Parking", tint: FGColor.accentYellow)
    static let familyFriendly = VenueFeatureDefinition(id: "family_friendly", iconName: "figure.2.and.child.holdinghands", label: "Family Friendly", tint: FGColor.accentGreen)
    static let handicapParking = VenueFeatureDefinition(id: "handicap_parking", iconName: "parkingsign.circle.fill", label: "Handicap Parking", tint: FGColor.accentBlue)
    static let soundOn = VenueFeatureDefinition(id: "sound_on", iconName: "speaker.wave.2.fill", label: "Sound On", tint: FGColor.accentYellow)
    static let liveMusic = VenueFeatureDefinition(id: "live_music", iconName: "music.note", label: "Live Music", tint: FGColor.gradientMiddle)
    static let poolTables = VenueFeatureDefinition(id: "pool_tables", iconName: "circle.grid.3x3.fill", label: "Pool Tables", tint: FGColor.accentGreen)
    static let rooftop = VenueFeatureDefinition(id: "rooftop", iconName: "building.2.crop.circle", label: "Rooftop", tint: FGColor.accentYellow)
    static let djNights = VenueFeatureDefinition(id: "dj_nights", iconName: "headphones", label: "DJ Nights", tint: FGColor.gradientMiddle)
    static let karaoke = VenueFeatureDefinition(id: "karaoke", iconName: "microphone.fill", label: "Karaoke", tint: FGColor.gradientMiddle)
    static let cocktails = VenueFeatureDefinition(id: "cocktails", iconName: "wineglass.fill", label: "Cocktails", tint: FGColor.accentYellow)
    static let craftBeer = VenueFeatureDefinition(id: "craft_beer", iconName: "mug.fill", label: "Craft Beer", tint: FGColor.accentYellow)
    static let futureFeatureTint = FGColor.gradientMiddle

    static let globalStandardCatalog: [VenueFeatureDefinition] = [
        screens,
        foodDrinks,
        wifi,
        projector,
        patio,
        rooftop,
        liveMusic,
        djNights,
        karaoke,
        poolTables,
        craftBeer,
        cocktails,
        familyFriendly,
        petFriendly,
        easyParking,
        handicapParking
    ]

    static let prioritizedRawFeatures: [VenueFeatureDefinition] = [
        soundOn,
        rooftop,
        liveMusic,
        djNights,
        karaoke,
        poolTables,
        craftBeer,
        cocktails,
        parkingAvailable,
        easyParking,
        familyFriendly,
        handicapParking
    ]

    static func screenLabel(count: Int?) -> String {
        guard let count else { return "Screens" }
        return "\(max(count, 1)) Screens"
    }
}

struct VenueFeatureDisplayItem: Identifiable {
    let id: String
    let iconName: String
    let label: String
    let tint: Color
    let availability: VenueFeatureAvailability

    var isEnabled: Bool { availability == .available }
}

enum VenueFeatureDisplaySource {
    static func configuredFeatureCount(for bar: BarVenue) -> Int {
        venueFeaturesForDisplay(bar).count
    }
}

func venueFeaturesForDisplay(_ bar: BarVenue) -> [VenueFeatureDisplayItem] {
    var items: [VenueFeatureDisplayItem] = []

    func append(_ definition: VenueFeatureDefinition, availability: VenueFeatureAvailability, labelOverride: String? = nil) {
        items.append(
            VenueFeatureDisplayItem(
                id: definition.id,
                iconName: definition.iconName,
                label: labelOverride ?? definition.label,
                tint: definition.tint,
                availability: availability
            )
        )
    }

    let rawFeatureTokens = venueRawFeatureTokens(bar.rawVenueFeatures)
    let mappedRawFeatures = rawFeatureTokens.compactMap(venueFeatureDefinitionForRawToken)
    let hasParkingAvailableToken = mappedRawFeatures.contains { $0.id == VenueFeatureDefinitions.parkingAvailable.id }
    let hasEasyParkingToken = mappedRawFeatures.contains { $0.id == VenueFeatureDefinitions.easyParking.id }
    
    func rawFeatureAvailability(_ definition: VenueFeatureDefinition) -> VenueFeatureAvailability {
        let isPresent = mappedRawFeatures.contains { $0.id == definition.id }
        return venueRawTokenFeatureAvailability(isPresent: isPresent, bar: bar)
    }

    func mergedEasyParkingAvailability() -> VenueFeatureAvailability {
        venueRawTokenFeatureAvailability(
            isPresent: hasEasyParkingToken || hasParkingAvailableToken,
            bar: bar
        )
    }
    
    append(
        VenueFeatureDefinitions.screens,
        availability: venueScreenAvailability(bar.screenCount),
        labelOverride: VenueFeatureDefinitions.screenLabel(count: bar.screenCount)
    )

    let rawFoodDrinksAvailable = mappedRawFeatures.contains { $0.id == VenueFeatureDefinitions.foodDrinks.id }
    append(VenueFeatureDefinitions.foodDrinks, availability: rawFoodDrinksAvailable ? .available : venueBoolFeatureAvailability(bar.servesFood))
    append(VenueFeatureDefinitions.wifi, availability: venueBoolFeatureAvailability(bar.hasWifi))
    append(VenueFeatureDefinitions.projector, availability: venueBoolFeatureAvailability(bar.hasProjector))
    append(VenueFeatureDefinitions.patio, availability: venueBoolFeatureAvailability(bar.hasGarden))
    append(VenueFeatureDefinitions.rooftop, availability: rawFeatureAvailability(VenueFeatureDefinitions.rooftop))
    append(VenueFeatureDefinitions.liveMusic, availability: rawFeatureAvailability(VenueFeatureDefinitions.liveMusic))
    append(VenueFeatureDefinitions.djNights, availability: rawFeatureAvailability(VenueFeatureDefinitions.djNights))
    append(VenueFeatureDefinitions.karaoke, availability: rawFeatureAvailability(VenueFeatureDefinitions.karaoke))
    append(VenueFeatureDefinitions.poolTables, availability: rawFeatureAvailability(VenueFeatureDefinitions.poolTables))
    append(VenueFeatureDefinitions.craftBeer, availability: rawFeatureAvailability(VenueFeatureDefinitions.craftBeer))
    append(VenueFeatureDefinitions.cocktails, availability: rawFeatureAvailability(VenueFeatureDefinitions.cocktails))
    append(VenueFeatureDefinitions.familyFriendly, availability: rawFeatureAvailability(VenueFeatureDefinitions.familyFriendly))
    append(VenueFeatureDefinitions.petFriendly, availability: venueBoolFeatureAvailability(bar.petFriendly))
    append(VenueFeatureDefinitions.easyParking, availability: mergedEasyParkingAvailability())
    append(VenueFeatureDefinitions.handicapParking, availability: rawFeatureAvailability(VenueFeatureDefinitions.handicapParking))
    return items
}

func topVenueFeaturesForCards(_ bar: BarVenue, limit: Int = 4) -> [VenueFeatureDisplayItem] {
    Array(venueFeaturesForDisplay(bar).filter(\.isEnabled).prefix(limit))
}

func compactVenueFeaturesForCards(_ bar: BarVenue, limit: Int = 5) -> [VenueFeatureDisplayItem] {
    let priorityIDs = [
        VenueFeatureDefinitions.screens.id,
        VenueFeatureDefinitions.foodDrinks.id,
        VenueFeatureDefinitions.wifi.id,
        VenueFeatureDefinitions.projector.id,
        VenueFeatureDefinitions.patio.id,
        VenueFeatureDefinitions.rooftop.id,
        VenueFeatureDefinitions.liveMusic.id,
        VenueFeatureDefinitions.djNights.id,
        VenueFeatureDefinitions.karaoke.id,
        VenueFeatureDefinitions.easyParking.id
    ]
    let prioritySet = Set(priorityIDs)
    return Array(
        venueFeaturesForDisplay(bar)
            .filter { $0.isEnabled && prioritySet.contains($0.id) }
            .prefix(limit)
    )
}

func venueMergedRawFeaturesLine(
    existingRawFeatures: String,
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
    craftBeer: Bool = false
) -> String {
    let knownDefinitionIDs = Set(
        VenueFeatureDefinitions.prioritizedRawFeatures
            .filter { $0.id != VenueFeatureDefinitions.soundOn.id }
            .map(\.id) + [VenueFeatureDefinitions.foodDrinks.id]
    )
    var bits = venueRawFeatureTokens(existingRawFeatures).filter { token in
        guard let definition = venueFeatureDefinitionForRawToken(token) else { return true }
        return !knownDefinitionIDs.contains(definition.id)
    }

    func add(_ definition: VenueFeatureDefinition, when isEnabled: Bool) {
        guard isEnabled else { return }
        bits.append(definition.label)
    }

    let shouldShowEasyParking = easyParking || parkingAvailable
    add(VenueFeatureDefinitions.rooftop, when: rooftop)
    add(VenueFeatureDefinitions.liveMusic, when: liveMusic)
    add(VenueFeatureDefinitions.djNights, when: djNights)
    add(VenueFeatureDefinitions.karaoke, when: karaoke)
    add(VenueFeatureDefinitions.poolTables, when: poolTables)
    add(VenueFeatureDefinitions.craftBeer, when: craftBeer)
    add(VenueFeatureDefinitions.cocktails, when: cocktails)
    add(VenueFeatureDefinitions.familyFriendly, when: familyFriendly)
    add(VenueFeatureDefinitions.easyParking, when: shouldShowEasyParking)
    add(VenueFeatureDefinitions.handicapParking, when: handicapParking)

    var seen = Set<String>()
    return bits.filter { token in
        let normalized = venueNormalizeFeatureText(token)
        guard !normalized.isEmpty, !seen.contains(normalized) else { return false }
        seen.insert(normalized)
        return true
    }
    .joined(separator: " · ")
}

func venueRawFeaturesContain(_ rawFeatures: String, definition: VenueFeatureDefinition) -> Bool {
    venueRawFeatureTokens(rawFeatures)
        .compactMap(venueFeatureDefinitionForRawToken)
        .contains { $0.id == definition.id }
}

private func venueBoolFeatureAvailability(_ value: Bool?) -> VenueFeatureAvailability {
    switch value {
    case true:
        return .available
    case false, nil:
        return .unavailable
    }
}

private func venueScreenAvailability(_ screenCount: Int?) -> VenueFeatureAvailability {
    guard let screenCount else { return .unavailable }
    return screenCount > 0 ? .available : .unavailable
}

private func venueRawTokenFeatureAvailability(isPresent: Bool, bar: BarVenue) -> VenueFeatureAvailability {
    if isPresent { return .available }
    return .unavailable
}

private func venueRawFeatureTokens(_ rawFeatures: String?) -> [String] {
    guard let rawFeatures else { return [] }
    return rawFeatures
        .components(separatedBy: CharacterSet(charactersIn: "·,\n;|"))
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}

private func venueFeatureDefinitionForRawToken(_ token: String) -> VenueFeatureDefinition? {
    let normalized = venueNormalizeFeatureText(token)
    if normalized.contains("cocktail") || normalized.contains("mixed drink") {
        return VenueFeatureDefinitions.cocktails
    }
    if normalized.contains("craft beer") || normalized.contains("draft beer") || normalized.contains("draught beer") {
        return VenueFeatureDefinitions.craftBeer
    }
    if normalized.contains("food") || normalized.contains("drink") || normalized.contains("full kitchen") || normalized.contains("kitchen") {
        return VenueFeatureDefinitions.foodDrinks
    }
    if normalized.contains("sound on") || normalized.contains("audio") {
        return VenueFeatureDefinitions.soundOn
    }
    if normalized.contains("rooftop") || normalized.contains("roof top") {
        return VenueFeatureDefinitions.rooftop
    }
    if normalized.contains("terrace") || normalized.contains("patio") {
        return VenueFeatureDefinitions.patio
    }
    if normalized.contains("live music") || normalized.contains("music") {
        return VenueFeatureDefinitions.liveMusic
    }
    if normalized.contains("dj") || normalized.contains("disc jockey") {
        return VenueFeatureDefinitions.djNights
    }
    if normalized.contains("karaoke") {
        return VenueFeatureDefinitions.karaoke
    }
    if normalized.contains("pool table") || normalized.contains("billiard") {
        return VenueFeatureDefinitions.poolTables
    }
    if normalized.contains("handicap parking") || normalized.contains("accessible parking") || normalized.contains("ada parking") {
        return VenueFeatureDefinitions.handicapParking
    }
    if normalized.contains("easy parking") {
        return VenueFeatureDefinitions.easyParking
    }
    if normalized.contains("parking available") || normalized.contains("parking") {
        return VenueFeatureDefinitions.parkingAvailable
    }
    if normalized.contains("family") || normalized.contains("kid") {
        return VenueFeatureDefinitions.familyFriendly
    }
    return nil
}

private func venueNormalizeFeatureText(_ value: String) -> String {
    value
        .lowercased()
        .replacingOccurrences(of: "\u{2011}", with: "-")
        .replacingOccurrences(of: "\u{2010}", with: "-")
        .replacingOccurrences(of: "&", with: "and")
        .replacingOccurrences(of: "/", with: " ")
        .replacingOccurrences(of: "-", with: " ")
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

struct VenueFeatureGrid: View {
    let items: [VenueFeatureDisplayItem]
    var columns: [GridItem] = [
        GridItem(.flexible(), spacing: FGSpacing.sm),
        GridItem(.flexible(), spacing: FGSpacing.sm),
        GridItem(.flexible(), spacing: FGSpacing.sm)
    ]

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        LazyVGrid(columns: columns, spacing: FGSpacing.sm) {
            ForEach(items) { item in
                let activeTint = FGColor.accentGreen
                let unavailableTint = FGColor.mutedText(colorScheme)
                let unknownTint = FGColor.secondaryText(colorScheme).opacity(colorScheme == .dark ? 0.72 : 0.82)
                let iconColor: Color = {
                    switch item.availability {
                    case .available: return activeTint
                    case .unavailable: return unavailableTint
                    case .unknown: return unknownTint
                    }
                }()
                let textColor: Color = {
                    switch item.availability {
                    case .available: return FGColor.primaryText(colorScheme)
                    case .unavailable: return FGColor.secondaryText(colorScheme)
                    case .unknown: return unknownTint
                    }
                }()
                let backgroundFill: Color = {
                    switch item.availability {
                    case .available:
                        return activeTint.opacity(colorScheme == .dark ? 0.10 : 0.07)
                    case .unavailable:
                        return Color.clear
                    case .unknown:
                        return Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.04)
                    }
                }()

                VStack(spacing: 6) {
                    Image(systemName: item.iconName)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(iconColor)
                        .frame(width: 28, height: 24)

                    Text(item.label)
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(textColor.opacity(item.availability == .unavailable ? 0.78 : 1))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity, minHeight: 72, alignment: .center)
                .padding(.horizontal, 5)
                .padding(.vertical, 7)
                .background(backgroundFill)
                .clipShape(RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
                .overlay {
                    if item.availability == .unknown {
                        RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous)
                            .strokeBorder(unknownTint.opacity(0.35), lineWidth: 1)
                    }
                }
                .overlay {
                    if item.availability == .unavailable {
                        unavailableFeatureSlashOverlay()
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityLabel(for: item))
                .onAppear {
#if DEBUG
                    if item.availability == .unavailable {
                        print("[VenueFeaturesDebug] unavailableFeatureRendered=\(item.label)")
                        print("[VenueFeaturesDebug] unavailableOverlayApplied=true")
                    }
#endif
                }
            }
        }
        .onAppear {
#if DEBUG
            print("[VenueFeatureDebug] featureOrderUpdated=true")
            print("[VenueFeatureDebug] removedDuplicateFullKitchen=true")
            print("[VenueFeatureDebug] addedNewFeatures=karaoke,cocktails,craft_beer")
            print("[VenueFeatureDebug] patioDisplayRenamedToTerrace=true")
            print("[VenueFeatureDebug] parkingDisplayMerged=true")
            print("[VenueFeatureDebug] featureGroupsUpdated=true")
            print("[VenueFeatureDebug] terraceIconApplied=true")
            print("[VenueFeatureDebug] globalStandardCatalogApplied=true")
            print("[VenueFeatureDebug] availableToAllVenueTypes=true")
            print("[VenueFeatureDebug] sharedFeatureCatalogApplied=true")
            print("[VenueFeatureDebug] sqlNeeded=false")
#endif
        }
    }

    private func accessibilityLabel(for item: VenueFeatureDisplayItem) -> String {
        let state: String
        switch item.availability {
        case .available: state = "available"
        case .unavailable: state = "not available"
        case .unknown: state = "unverified"
        }
        return "\(item.label), \(state)"
    }

    private func unavailableFeatureSlashOverlay() -> some View {
        let slashTint = Color(red: 1.0, green: 0.35, blue: 0.37).opacity(colorScheme == .dark ? 0.72 : 0.64)
        return GeometryReader { proxy in
            Path { path in
                let insetX = max(14, proxy.size.width * 0.20)
                let insetY = max(12, proxy.size.height * 0.18)
                path.move(to: CGPoint(x: insetX, y: insetY))
                path.addLine(to: CGPoint(x: proxy.size.width - insetX, y: proxy.size.height - insetY))
            }
            .stroke(
                slashTint,
                style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round)
            )
            .shadow(color: slashTint.opacity(0.16), radius: 2, x: 0, y: 1)
        }
        .allowsHitTesting(false)
    }
}
