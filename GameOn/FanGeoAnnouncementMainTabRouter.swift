import SwiftUI

/// Routes announcement CTA tab requests without growing ``MainTabView`` modifier chains.
struct FanGeoAnnouncementMainTabRouter: View {
    @ObservedObject var viewModel: MapViewModel
    var onSelectTab: (String) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: viewModel.requestedMainTabRaw) { _, raw in
                guard let raw else { return }
                onSelectTab(raw)
                viewModel.requestedMainTabRaw = nil
            }
    }
}
