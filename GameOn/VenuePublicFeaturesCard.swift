import SwiftUI

/// Read-only venue amenities for Discover / ``VenueDetailView``: same 3-column grid, labels, and icons as Manage Venue (no +/-, no toggles, no slash badges).
struct VenuePublicFeaturesCard: View {
    let bar: BarVenue

    private var items: [VenueFeatureDisplayItem] {
        venueFeaturesForDisplay(bar)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Venue Features")
                .font(.headline)
                .fontWeight(.bold)

            VenueFeatureGrid(items: items)
        }
        .padding(12)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}
