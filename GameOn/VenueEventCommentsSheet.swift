import SwiftUI

/// Sheet host for ``VenueEventCommentsView``; keeps the same presentation API as Discover.
struct VenueEventCommentsSheet: View {
    @ObservedObject var viewModel: MapViewModel
    let venueEventID: UUID

    var body: some View {
        NavigationStack {
            VenueEventCommentsView(viewModel: viewModel, venueEventID: venueEventID)
                .navigationTitle("Fan updates")
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}
