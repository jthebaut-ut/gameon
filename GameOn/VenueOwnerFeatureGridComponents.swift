import SwiftUI

// MARK: - Venue feature grid (Manage Venue / Add Location / Business signup)

/// Screen count tile with +/- controls; matches ``VenueOwnerDashboardView`` styling.
struct VenueOwnerScreensFeatureTile: View {
    @Binding var totalScreens: Int
    var minScreens: Int = 1
    var maxScreens: Int = 100

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "display")
                .font(.title2)
                .foregroundStyle(Color.green)

            Text("\(totalScreens) Screens")
                .font(.caption)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)
                .foregroundStyle(.primary)
                .minimumScaleFactor(0.75)
                .lineLimit(2)
                .frame(maxWidth: .infinity)

            HStack(spacing: 0) {
                Button {
                    if totalScreens > minScreens { totalScreens -= 1 }
                } label: {
                    Image(systemName: "minus")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(totalScreens > minScreens ? Color.primary : Color.secondary.opacity(0.35))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .buttonStyle(.plain)
                .disabled(totalScreens <= minScreens)
                .accessibilityLabel("Decrease screen count")

                Rectangle()
                    .fill(Color.secondary.opacity(0.22))
                    .frame(width: 1, height: 14)

                Button {
                    if totalScreens < maxScreens { totalScreens += 1 }
                } label: {
                    Image(systemName: "plus")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(totalScreens < maxScreens ? Color.primary : Color.secondary.opacity(0.35))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .buttonStyle(.plain)
                .disabled(totalScreens >= maxScreens)
                .accessibilityLabel("Increase screen count")
            }
            .frame(width: 104, height: 26)
            .frame(maxWidth: .infinity)
            .background(Color.gray.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
    }
}

struct VenueOwnerFeatureToggleTile: View {
    let icon: String
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(isOn ? Color.green : Color.gray.opacity(0.62))

                Text(label)
                    .font(.caption)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(isOn ? Color.primary : Color.secondary)
                    .minimumScaleFactor(0.8)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .padding(.horizontal, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// Three-column amenity + screen editor matching dashboard / Discover feature card chrome.
struct AddLocationVenueFeaturesGrid: View {
    @Binding var screenCount: Int
    @Binding var servesFood: Bool
    @Binding var hasWifi: Bool
    @Binding var hasGarden: Bool
    @Binding var hasProjector: Bool
    @Binding var petFriendly: Bool
    @Binding var parkingAvailable: Bool
    @Binding var familyFriendly: Bool

    var maxScreenCount: Int = 40

    private var columns: [GridItem] {
        [
            GridItem(.flexible(), spacing: 6),
            GridItem(.flexible(), spacing: 6),
            GridItem(.flexible(), spacing: 6),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Venue Features")
                .font(.headline)
                .fontWeight(.bold)

            LazyVGrid(columns: columns, alignment: .center, spacing: 8) {
                VenueOwnerScreensFeatureTile(totalScreens: $screenCount, minScreens: 1, maxScreens: maxScreenCount)
                VenueOwnerFeatureToggleTile(icon: "fork.knife", label: "Food / Drinks", isOn: $servesFood)
                VenueOwnerFeatureToggleTile(icon: "wifi", label: "WiFi", isOn: $hasWifi)
                VenueOwnerFeatureToggleTile(icon: "chair.lounge.fill", label: "Outdoor / Patio", isOn: $hasGarden)
                VenueOwnerFeatureToggleTile(icon: "video.fill", label: "Projector", isOn: $hasProjector)
                VenueOwnerFeatureToggleTile(icon: "pawprint.fill", label: "Pet Friendly", isOn: $petFriendly)
                VenueOwnerFeatureToggleTile(icon: "car.fill", label: "Parking", isOn: $parkingAvailable)
                VenueOwnerFeatureToggleTile(icon: "figure.2.and.child.holdinghands", label: "Family Friendly", isOn: $familyFriendly)
            }
        }
        .padding(12)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}
