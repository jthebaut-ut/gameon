import SwiftUI
import UIKit

/// Root view for the single-window app; delegates UI to ``MainTabView``.
struct ContentView: View {
    @StateObject private var viewModel = MapViewModel()
    @StateObject private var chatViewModel = ChatViewModel()
    @StateObject private var bootstrapCoordinator = BootstrapLoadingCoordinator()
    @Environment(\.scenePhase) private var scenePhase
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
            } else if let ban = viewModel.activeAccountBan {
                AccountSuspensionGateView(viewModel: viewModel, ban: ban)
                    .zIndex(2)
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
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                if viewModel.activeAccountBan != nil {
                    await viewModel.refreshActiveBanGateAndRestoreSessionIfAllowed(reason: "foreground")
                } else {
                    await viewModel.refreshActiveBanGate(reason: "foreground")
                }
            }
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

private struct AccountSuspensionGateView: View {
    @ObservedObject var viewModel: MapViewModel
    let ban: FanGeoAccountBan

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 32)

            Image(systemName: "hand.raised.fill")
                .font(.system(size: 46, weight: .bold))
                .foregroundStyle(FGColor.dangerRed)

            VStack(spacing: 10) {
                Text("Account suspended")
                    .font(.system(size: 28, weight: .black, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .multilineTextAlignment(.center)

                Text(primaryMessage)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .multilineTextAlignment(.center)

                if let remainingMessage {
                    Text(remainingMessage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .multilineTextAlignment(.center)
                }

                Text("For questions, contact support@fangeosports.com.")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
            .padding(22)
            .frame(maxWidth: 420)
            .background(FGAdaptiveSurface.cardElevated, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(FGColor.divider(colorScheme).opacity(0.45), lineWidth: 1)
            }

            Button {
                Task {
                    await viewModel.refreshActiveBanGateAndRestoreSessionIfAllowed(reason: "manualSuspensionRefresh")
                }
            } label: {
                Text(viewModel.isCheckingActiveBan ? "Checking..." : "Check status")
                    .font(.headline.weight(.bold))
                    .frame(maxWidth: 260)
                    .padding(.vertical, 14)
                    .background(FGColor.accentBlue, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isCheckingActiveBan)

            Spacer(minLength: 32)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fanGeoScreenBackground()
    }

    private var primaryMessage: String {
        if ban.isPermanent {
            return "Your account has been permanently suspended."
        }
        return "Your account is suspended until \(formattedBanEnd)."
    }

    private var remainingMessage: String? {
        guard !ban.isPermanent else { return nil }
        guard let remainingSeconds = ban.remainingSeconds else {
            return "You can return after the suspension expires."
        }
        return "You can return in \(Self.remainingTimeText(seconds: remainingSeconds))."
    }

    private var formattedBanEnd: String {
        guard let bannedUntil = ban.bannedUntil else {
            return ban.bannedUntilRaw ?? "the scheduled end time"
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: bannedUntil)
    }

    private static func remainingTimeText(seconds: Int) -> String {
        let clamped = max(0, seconds)
        let days = clamped / 86_400
        let hours = (clamped % 86_400) / 3_600
        let minutes = (clamped % 3_600) / 60

        if days > 0 {
            return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
        }
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        if minutes > 0 {
            return "\(minutes)m"
        }
        return "less than 1 minute"
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
