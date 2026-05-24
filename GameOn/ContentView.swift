import SwiftUI
import UIKit

/// Root view for the single-window app; delegates UI to ``MainTabView``.
struct ContentView: View {
    @StateObject private var viewModel = MapViewModel()
    @StateObject private var chatViewModel = ChatViewModel()
    @StateObject private var bootstrapCoordinator = BootstrapLoadingCoordinator()
    #if DEBUG
    @State private var debugSplashMinimumElapsed = false
    #endif

    var body: some View {
        ZStack {
            Color.white
                .ignoresSafeArea()

            if shouldShowSplash {
                FanGeoSplashView()
                    .zIndex(1)
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
                .zIndex(0)
            }
        }
        .onAppear {
            #if DEBUG
            print("[LaunchPathDebug] ContentViewMounted=true")
            print("[LaunchPathDebug] isBootstrapping=\(bootstrapCoordinator.isBootstrapping)")
            print("[LaunchPathDebug] splashMinDurationActive=\(!debugSplashMinimumElapsed)")
            #endif
        }
        .onChange(of: bootstrapCoordinator.isBootstrapping) {
            #if DEBUG
            print("[LaunchPathDebug] isBootstrapping=\(bootstrapCoordinator.isBootstrapping)")
            #endif
        }
        .onOpenURL { url in
            Task {
                await viewModel.handleEmailVerificationDeepLink(url)
                await viewModel.handlePasswordResetDeepLink(url)
            }
        }
        .background(PasswordResetRecoveryOverlayWindowPresenter(viewModel: viewModel))
        .task {
#if DEBUG
            print("[ChatViewModelInstanceDebug] ContentView root ChatViewModel id=\(ObjectIdentifier(chatViewModel))")
            print("[MainActorDebug] ContentView bootstrap task actor=MainActor")
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                debugSplashMinimumElapsed = true
                print("[LaunchPathDebug] splashMinDurationActive=false")
            }
#endif
            await bootstrapCoordinator.beginIfNeeded(
                viewModel: viewModel,
                chatViewModel: chatViewModel
            )
        }
    }

    private var shouldShowSplash: Bool {
        #if DEBUG
        return bootstrapCoordinator.isBootstrapping || !debugSplashMinimumElapsed
        #else
        return bootstrapCoordinator.isBootstrapping
        #endif
    }
}

private struct PasswordResetRecoveryOverlayWindowPresenter: UIViewRepresentable {
    @ObservedObject var viewModel: MapViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isHidden = true
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.update(viewModel: viewModel, sourceView: uiView)
    }

    final class Coordinator {
        private var overlayWindow: UIWindow?
        private weak var previousKeyWindow: UIWindow?
        private var hostingController: UIHostingController<PasswordResetCreatePasswordSheet>?
        private var isShowingOverlay = false

        @MainActor
        func update(viewModel: MapViewModel, sourceView: UIView) {
            let shouldShowOverlay = viewModel.isShowingPasswordResetCreateSheet
                || viewModel.isPasswordResetRecoverySessionActive
            guard shouldShowOverlay else {
                dismissOverlayIfNeeded()
                return
            }

            let host = hostingController ?? UIHostingController(
                rootView: PasswordResetCreatePasswordSheet(viewModel: viewModel)
            )
            host.rootView = PasswordResetCreatePasswordSheet(viewModel: viewModel)
            host.view.backgroundColor = .clear
            hostingController = host

            if overlayWindow == nil {
                guard let windowScene = sourceView.window?.windowScene
                    ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
                else { return }

                let window = UIWindow(windowScene: windowScene)
                window.windowLevel = .alert + 100
                window.backgroundColor = .clear
                window.rootViewController = host
                previousKeyWindow = windowScene.windows.first(where: \.isKeyWindow)
                overlayWindow = window
            } else {
                overlayWindow?.rootViewController = host
            }

            overlayWindow?.makeKeyAndVisible()
            if !isShowingOverlay {
                isShowingOverlay = true
                print("[PasswordResetDebug] rootOverlayPresented=true")
                print("[PasswordResetDebug] recoveryOverlayAboveAll=true")
            }
        }

        @MainActor
        private func dismissOverlayIfNeeded() {
            guard overlayWindow != nil || isShowingOverlay else { return }
            overlayWindow?.isHidden = true
            overlayWindow?.rootViewController = nil
            overlayWindow = nil
            hostingController = nil
            previousKeyWindow?.makeKey()
            previousKeyWindow = nil
            isShowingOverlay = false
            print("[PasswordResetDebug] rootOverlayDismissed=true")
        }
    }
}
