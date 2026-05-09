import SwiftUI

/// Sheet host for ``VenueEventCommentsView``; keeps the same presentation API as Discover.
struct VenueEventCommentsSheet: View {
    @ObservedObject var viewModel: MapViewModel
    let venueEventID: UUID

    private var headerSubtitle: String {
        guard let row = viewModel.venueEventRows.first(where: { $0.id == venueEventID }) else {
            return ""
        }
        let game = row.event_title ?? "Game"
        let venue = row.venue_name ?? "Venue"
        return "\(game) · \(venue)"
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                if !headerSubtitle.isEmpty {
                    Text(headerSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 4)
                }
                VenueEventCommentsView(viewModel: viewModel, venueEventID: venueEventID)
            }
            .navigationTitle("Fan Updates")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
