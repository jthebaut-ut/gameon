import SwiftUI

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
    static let patio = VenueFeatureDefinition(id: "patio", iconName: "chair.lounge.fill", label: "Patio", tint: FGColor.businessGreen)
    static let projector = VenueFeatureDefinition(id: "projector", iconName: "video.fill", label: "Projector", tint: FGColor.gradientMiddle)
    static let petFriendly = VenueFeatureDefinition(id: "pet_friendly", iconName: "pawprint.fill", label: "Pet Friendly", tint: FGColor.businessGreen)
    static let parkingAvailable = VenueFeatureDefinition(id: "parking_available", iconName: "car.fill", label: "Parking Available", tint: FGColor.accentYellow)
    static let easyParking = VenueFeatureDefinition(id: "easy_parking", iconName: "parkingsign.circle.fill", label: "Easy Parking", tint: FGColor.accentYellow)
    static let familyFriendly = VenueFeatureDefinition(id: "family_friendly", iconName: "figure.2.and.child.holdinghands", label: "Family Friendly", tint: FGColor.accentGreen)
    static let futureFeatureTint = FGColor.gradientMiddle

    static func screenLabel(count: Int) -> String {
        "\(max(count, 1)) Screens"
    }
}

struct VenueFeatureDisplayItem: Identifiable {
    let id: String
    let iconName: String
    let label: String
    let tint: Color
    let isEnabled: Bool
}

enum VenueFeatureDisplaySource {
    static func configuredFeatureCount(for bar: BarVenue) -> Int {
        venueFeaturesForDisplay(bar).count
    }
}

func venueFeaturesForDisplay(_ bar: BarVenue) -> [VenueFeatureDisplayItem] {
    var items: [VenueFeatureDisplayItem] = [
        VenueFeatureDisplayItem(
            id: VenueFeatureDefinitions.screens.id,
            iconName: VenueFeatureDefinitions.screens.iconName,
            label: VenueFeatureDefinitions.screenLabel(count: bar.screenCount),
            tint: VenueFeatureDefinitions.screens.tint,
            isEnabled: true
        )
    ]

    func append(_ definition: VenueFeatureDefinition, enabled: Bool) {
        items.append(
            VenueFeatureDisplayItem(
                id: definition.id,
                iconName: definition.iconName,
                label: definition.label,
                tint: definition.tint,
                isEnabled: enabled
            )
        )
    }

    append(VenueFeatureDefinitions.foodDrinks, enabled: bar.servesFood)
    append(VenueFeatureDefinitions.wifi, enabled: bar.hasWifi)
    append(VenueFeatureDefinitions.patio, enabled: bar.hasGarden)
    append(VenueFeatureDefinitions.projector, enabled: bar.hasProjector)
    append(VenueFeatureDefinitions.petFriendly, enabled: bar.petFriendly)

    let rawFeatureTokens = venueRawFeatureTokens(bar.rawVenueFeatures)
    let mappedRawFeatures = rawFeatureTokens.compactMap(venueFeatureDefinitionForRawToken)
    append(VenueFeatureDefinitions.parkingAvailable, enabled: mappedRawFeatures.contains { $0.id == VenueFeatureDefinitions.parkingAvailable.id })
    append(VenueFeatureDefinitions.easyParking, enabled: mappedRawFeatures.contains { $0.id == VenueFeatureDefinitions.easyParking.id })
    append(VenueFeatureDefinitions.familyFriendly, enabled: mappedRawFeatures.contains { $0.id == VenueFeatureDefinitions.familyFriendly.id })

    let existingLabels = Set(items.map { venueNormalizeFeatureText($0.label) })
    let existingDefinitionIDs = Set(items.map(\.id))
    let futureItems = rawFeatureTokens.compactMap { token -> VenueFeatureDisplayItem? in
        if let definition = venueFeatureDefinitionForRawToken(token), existingDefinitionIDs.contains(definition.id) {
            return nil
        }

        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let normalized = venueNormalizeFeatureText(trimmed)
        guard !existingLabels.contains(normalized), !normalized.contains("screen") else { return nil }

        return VenueFeatureDisplayItem(
            id: "raw_\(normalized)",
            iconName: "sparkles",
            label: trimmed,
            tint: VenueFeatureDefinitions.futureFeatureTint,
            isEnabled: true
        )
    }

    items.append(contentsOf: futureItems)
    return items
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
                let inactiveTint = FGColor.mutedText(colorScheme)
                let iconColor = item.isEnabled ? activeTint : inactiveTint
                let textColor = item.isEnabled ? FGColor.primaryText(colorScheme) : FGColor.secondaryText(colorScheme)

                VStack(spacing: 6) {
                    Image(systemName: item.iconName)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(iconColor)
                        .frame(height: 24)

                    Text(item.label)
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(textColor.opacity(item.isEnabled ? 1 : 0.78))
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity, minHeight: 70, alignment: .center)
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
                .background(item.isEnabled ? activeTint.opacity(colorScheme == .dark ? 0.10 : 0.07) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(item.label), \(item.isEnabled ? "available" : "not available")")
            }
        }
    }
}
