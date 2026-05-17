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
                PublicProfilePresentationHost(
                    viewModel: viewModel,
                    chatViewModel: chatViewModel
                ) {
                    MainTabView(
                        viewModel: viewModel,
                        chatViewModel: chatViewModel,
                        performsInitialBootstrap: bootstrapCoordinator.shouldUseMainTabFallbackBootstrap
                    )
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.45), value: bootstrapCoordinator.isBootstrapping)
        .task {
#if DEBUG
            print("[ChatViewModelInstanceDebug] ContentView root ChatViewModel id=\(ObjectIdentifier(chatViewModel))")
            print("[MainActorDebug] ContentView bootstrap task actor=MainActor")
#endif
            await bootstrapCoordinator.beginIfNeeded(
                viewModel: viewModel,
                chatViewModel: chatViewModel
            )
        }
    }
}
