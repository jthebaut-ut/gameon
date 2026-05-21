import SwiftUI

/// Sheet host for ``VenueEventCommentsView``; keeps the same presentation API as Discover.
struct VenueEventCommentsSheet: View {
    @ObservedObject var viewModel: MapViewModel
    let venueEventID: UUID

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

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
                VenueEventCommentsView(
                    viewModel: viewModel,
                    fanUpdatesStore: viewModel.fanUpdatesStore,
                    venueEventID: venueEventID
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(sheetRootBackground)
            .navigationTitle(L10n.t("fan_updates", languageCode: appLanguageRaw))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(sheetRootBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(navigationChromeColorScheme, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
#if DEBUG
                        print("[FanUpdatesSheetDebug] closeButtonTapped=true")
#endif
                        withAnimation(.easeInOut(duration: 0.2)) {
                            dismiss()
                        }
#if DEBUG
                        print("[FanUpdatesSheetDebug] dismissedFromCloseButton=true")
#endif
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(FGColor.primaryText(colorScheme).opacity(0.72))
                            .frame(width: 32, height: 32)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay {
                                Circle()
                                    .strokeBorder(FGColor.divider(colorScheme).opacity(0.58), lineWidth: 1)
                            }
                            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.08), radius: 8, y: 3)
                    }
                    .buttonStyle(FGPremiumPressButtonStyle(pressedScale: 0.92, hapticOnPress: false))
                    .accessibilityLabel("Close Fan Updates")
                }
            }
        }
    }
}
