import SwiftUI

/// Root view for the single-window app; delegates UI to ``MainTabView``.
struct ContentView: View {
    @StateObject private var viewModel = MapViewModel()
    @StateObject private var chatViewModel = ChatViewModel()
    @StateObject private var bootstrapCoordinator = BootstrapLoadingCoordinator()

    var body: some View {
        ZStack {
            if bootstrapCoordinator.isBootstrapping {
                FanGeoSplashView(bootstrapError: bootstrapCoordinator.bootstrapError)
                    .transition(.opacity)
            } else {
                MainTabView(
                    viewModel: viewModel,
                    chatViewModel: chatViewModel,
                    performsInitialBootstrap: bootstrapCoordinator.shouldUseMainTabFallbackBootstrap
                )
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.45), value: bootstrapCoordinator.isBootstrapping)
        .task {
            await bootstrapCoordinator.beginIfNeeded(
                viewModel: viewModel,
                chatViewModel: chatViewModel
            )
        }
    }
}
