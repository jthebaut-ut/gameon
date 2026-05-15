import SwiftUI

/// Sheet host for ``VenueEventCommentsView``; keeps the same presentation API as Discover.
struct VenueEventCommentsSheet: View {
    @ObservedObject var viewModel: MapViewModel
    let venueEventID: UUID

    @Environment(\.colorScheme) private var colorScheme

    private var headerSubtitle: String {
        guard let row = viewModel.venueEventRows.first(where: { $0.id == venueEventID }) else {
            return ""
        }
        let game = row.event_title ?? "Game"
        let venue = row.venue_name ?? "Venue"
        return "\(game) · \(venue)"
    }

    private var sheetRootBackground: Color {
        colorScheme == .dark ? .black : Color(uiColor: .systemGroupedBackground)
    }

    private var headerSubtitleColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.7) : Color.primary.opacity(0.65)
    }

    private var navigationChromeColorScheme: ColorScheme {
        colorScheme == .dark ? .dark : .light
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                if !headerSubtitle.isEmpty {
                    Text(headerSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(headerSubtitleColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 4)
                }
                VenueEventCommentsView(viewModel: viewModel, venueEventID: venueEventID)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(sheetRootBackground)
            .navigationTitle("Fan Updates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(sheetRootBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(navigationChromeColorScheme, for: .navigationBar)
        }
    }
}
