import Combine
import Foundation
import SwiftUI

@MainActor
final class BootstrapLoadingCoordinator: ObservableObject {
    @Published private(set) var isBootstrapping = true
    @Published private(set) var bootstrapError: String?
    @Published private(set) var shouldUseMainTabFallbackBootstrap = false

    private var didStart = false
    private let minimumVisibleSeconds: TimeInterval = FanGeoSplashAnimation.minimumVisibleDuration
    private let maximumWaitSeconds: TimeInterval = 3.8

    func beginIfNeeded(
        viewModel: MapViewModel,
        chatViewModel: ChatViewModel
    ) async {
        guard !didStart else { return }
        didStart = true

        let startedAt = Date()
        let bootstrapTask = Task {
            await Self.performCriticalBootstrap(
                viewModel: viewModel,
                chatViewModel: chatViewModel
            )
        }

        let completedInTime = await waitForCompletion(
            bootstrapTask,
            timeoutSeconds: maximumWaitSeconds
        )

        let elapsed = Date().timeIntervalSince(startedAt)
        if elapsed < minimumVisibleSeconds {
            let remaining = minimumVisibleSeconds - elapsed
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        }

        if completedInTime {
            shouldUseMainTabFallbackBootstrap = false
            LaunchBootstrapState.markCriticalBootstrapCompleted()
        } else {
            bootstrapError = "Opening FanGeo while the rest finishes loading."
            print("[BusinessLogoutTrace] bootstrapTimeoutAuthRestoreContinues=true")
            shouldUseMainTabFallbackBootstrap = true
            Task { [weak self, weak viewModel, weak chatViewModel] in
                await bootstrapTask.value
                guard let self, let viewModel, let chatViewModel else { return }
                await MainActor.run {
                    self.scheduleWarmPreload(viewModel: viewModel, chatViewModel: chatViewModel)
                }
            }
        }

        #if DEBUG
        print("[FanGeoLoadingDebug] appReady")
        #endif
        isBootstrapping = false
        print("[BusinessLaunchPerf] splashNoLongerBlockedByBusinessRefresh=true")
        if completedInTime {
            scheduleWarmPreload(viewModel: viewModel, chatViewModel: chatViewModel)
        }
    }

    /// Critical launch path only — must stay fast enough for splash dismiss.
    static func performCriticalBootstrap(
        viewModel: MapViewModel,
        chatViewModel: ChatViewModel
    ) async {
        let criticalStart = Date()
        print("[LaunchPerf] criticalStart")

        await viewModel.renderCachedDiscoverCore()

        await viewModel.prepareInitialDiscoverRegionAndPreload()

        await viewModel.bootstrapAuthSessionOnly()

        if LaunchBootstrapState.markLaunchDiscoverCoreRefreshStarted() {
            await viewModel.refreshDiscoverCoreInBackground()
        } else {
            print("[LaunchPerf] duplicateSkipped reason=launchDiscoverCoreRefresh")
        }

        let shouldLoadChatBadge = await MainActor.run {
            viewModel.isAuthenticatedForSocialFeatures
        }
        if shouldLoadChatBadge {
            await chatViewModel.refreshUnreadDirectMessageCount()
        } else {
            await MainActor.run {
                chatViewModel.clearForSignOut()
            }
        }

        LaunchBootstrapState.markCriticalBootstrapCompleted()

        let criticalMs = Int(Date().timeIntervalSince(criticalStart) * 1000)
        print("[LaunchPerf] criticalEnd ms=\(criticalMs)")
    }

    private func scheduleWarmPreload(
        viewModel: MapViewModel,
        chatViewModel: ChatViewModel
    ) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            LaunchWarmPreloadCoordinator.shared.beginIfNeeded(
                viewModel: viewModel,
                chatViewModel: chatViewModel,
                accountTabVisible: false
            )
        }
    }

    private func waitForCompletion(
        _ task: Task<Void, Never>,
        timeoutSeconds: TimeInterval
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await task.value
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                return false
            }

            let finished = await group.next() ?? true
            group.cancelAll()
            return finished
        }
    }
}
