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
    static let patio = VenueFeatureDefinition(id: "patio", iconName: "chair.lounge.fill", label: "Patio", tint: FGColor.businessGreen)
    static let projector = VenueFeatureDefinition(id: "projector", iconName: "video.fill", label: "Projector", tint: FGColor.gradientMiddle)
    static let petFriendly = VenueFeatureDefinition(id: "pet_friendly", iconName: "pawprint.fill", label: "Pet Friendly", tint: FGColor.businessGreen)
    static let parkingAvailable = VenueFeatureDefinition(id: "parking_available", iconName: "car.fill", label: "Parking Available", tint: FGColor.accentYellow)
    static let easyParking = VenueFeatureDefinition(id: "easy_parking", iconName: "parkingsign.circle.fill", label: "Easy Parking", tint: FGColor.accentYellow)
    static let familyFriendly = VenueFeatureDefinition(id: "family_friendly", iconName: "figure.2.and.child.holdinghands", label: "Family Friendly", tint: FGColor.accentGreen)
    static let futureFeatureTint = FGColor.gradientMiddle

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
    var items: [VenueFeatureDisplayItem] = [
        VenueFeatureDisplayItem(
            id: VenueFeatureDefinitions.screens.id,
            iconName: VenueFeatureDefinitions.screens.iconName,
            label: VenueFeatureDefinitions.screenLabel(count: bar.screenCount),
            tint: VenueFeatureDefinitions.screens.tint,
            availability: venueScreenAvailability(bar.screenCount)
        )
    ]

    func append(_ definition: VenueFeatureDefinition, availability: VenueFeatureAvailability) {
        items.append(
            VenueFeatureDisplayItem(
                id: definition.id,
                iconName: definition.iconName,
                label: definition.label,
                tint: definition.tint,
                availability: availability
            )
        )
    }

    append(VenueFeatureDefinitions.foodDrinks, availability: venueBoolFeatureAvailability(bar.servesFood))
    append(VenueFeatureDefinitions.wifi, availability: venueBoolFeatureAvailability(bar.hasWifi))
    append(VenueFeatureDefinitions.patio, availability: venueBoolFeatureAvailability(bar.hasGarden))
    append(VenueFeatureDefinitions.projector, availability: venueBoolFeatureAvailability(bar.hasProjector))
    append(VenueFeatureDefinitions.petFriendly, availability: venueBoolFeatureAvailability(bar.petFriendly))

    let rawFeatureTokens = venueRawFeatureTokens(bar.rawVenueFeatures)
    let mappedRawFeatures = rawFeatureTokens.compactMap(venueFeatureDefinitionForRawToken)
    append(
        VenueFeatureDefinitions.parkingAvailable,
        availability: venueRawTokenFeatureAvailability(
            isPresent: mappedRawFeatures.contains { $0.id == VenueFeatureDefinitions.parkingAvailable.id },
            bar: bar
        )
    )
    append(
        VenueFeatureDefinitions.easyParking,
        availability: venueRawTokenFeatureAvailability(
            isPresent: mappedRawFeatures.contains { $0.id == VenueFeatureDefinitions.easyParking.id },
            bar: bar
        )
    )
    append(
        VenueFeatureDefinitions.familyFriendly,
        availability: venueRawTokenFeatureAvailability(
            isPresent: mappedRawFeatures.contains { $0.id == VenueFeatureDefinitions.familyFriendly.id },
            bar: bar
        )
    )

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
            availability: .available
        )
    }

    items.append(contentsOf: futureItems)
    return items
}

private func venueBoolFeatureAvailability(_ value: Bool?) -> VenueFeatureAvailability {
    switch value {
    case true:
        return .available
    case false:
        return .unavailable
    case nil:
        return .unknown
    }
}

private func venueScreenAvailability(_ screenCount: Int?) -> VenueFeatureAvailability {
    guard let screenCount else { return .unknown }
    return screenCount > 0 ? .available : .unavailable
}

private func venueRawTokenFeatureAvailability(isPresent: Bool, bar: BarVenue) -> VenueFeatureAvailability {
    if isPresent { return .available }
    return bar.hasBusinessVerifiedFeatures ? .unavailable : .unknown
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
                        .frame(height: 24)

                    Text(item.label)
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(textColor.opacity(item.availability == .unavailable ? 0.78 : 1))
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity, minHeight: 70, alignment: .center)
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
                .background(backgroundFill)
                .clipShape(RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
                .overlay {
                    if item.availability == .unknown {
                        RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous)
                            .strokeBorder(unknownTint.opacity(0.35), lineWidth: 1)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityLabel(for: item))
            }
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
}
