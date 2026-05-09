import SwiftUI

/// Read-only venue amenities for Discover / ``VenueDetailView``: same 3-column grid, labels, and icons as Manage Venue (no +/-, no toggles, no slash badges).
struct VenuePublicFeaturesCard: View {
    let bar: BarVenue

    private var columns: [GridItem] {
        [
            GridItem(.flexible(), spacing: 6),
            GridItem(.flexible(), spacing: 6),
            GridItem(.flexible(), spacing: 6)
        ]
    }

    private var screensTitle: String {
        "\(bar.screenCount) Screens"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Venue Features")
                .font(.headline)
                .fontWeight(.bold)

            LazyVGrid(columns: columns, alignment: .center, spacing: 8) {
                readOnlyTile(icon: "display", title: screensTitle, enabled: true)
                readOnlyTile(icon: "fork.knife", title: "Food / Drinks", enabled: bar.servesFood)
                readOnlyTile(icon: "wifi", title: "WiFi", enabled: bar.hasWifi)
                readOnlyTile(icon: "chair.lounge.fill", title: "Patio", enabled: bar.hasGarden)
                readOnlyTile(icon: "video.fill", title: "Projector", enabled: bar.hasProjector)
                readOnlyTile(icon: "pawprint.fill", title: "Pet Friendly", enabled: bar.petFriendly)
                readOnlyTile(icon: "car.fill", title: "Parking Available", enabled: false)
                readOnlyTile(icon: "parkingsign.circle.fill", title: "Easy Parking", enabled: false)
                readOnlyTile(icon: "figure.2.and.child.holdinghands", title: "Family Friendly", enabled: false)
            }
        }
        .padding(12)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private func readOnlyTile(icon: String, title: String, enabled: Bool) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(enabled ? Color.green : Color.gray.opacity(0.62))

            Text(title)
                .font(.caption)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)
                .foregroundStyle(enabled ? Color.primary : Color.secondary)
                .minimumScaleFactor(0.8)
                .lineLimit(2)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .padding(.horizontal, 2)
    }
}
