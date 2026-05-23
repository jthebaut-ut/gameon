import Foundation

/// Post-splash staggered preload for profile, chat, calendar, and social surfaces (does not block Discover first paint).
@MainActor
final class LaunchWarmPreloadCoordinator {
    static let shared = LaunchWarmPreloadCoordinator()

    private var preloadTask: Task<Void, Never>?

    private init() {}

    func beginIfNeeded(
        viewModel: MapViewModel,
        chatViewModel: ChatViewModel,
        accountTabVisible: Bool
    ) {
        guard LaunchBootstrapState.didCompleteCriticalBootstrap else {
            print("[LaunchPerf] duplicateSkipped reason=criticalBootstrapIncomplete")
            return
        }
        guard LaunchBootstrapState.markWarmPreloadStarted() else {
            print("[LaunchPerf] duplicateSkipped reason=warmPreloadAlreadyStarted")
            return
        }

        preloadTask?.cancel()
        preloadTask = Task(priority: .utility) { [weak viewModel, weak chatViewModel] in
            guard let viewModel, let chatViewModel else { return }
            await self.runStaggeredWarmPreload(
                viewModel: viewModel,
                chatViewModel: chatViewModel,
                accountTabVisible: accountTabVisible
            )
        }
    }

    func cancel() {
        preloadTask?.cancel()
        preloadTask = nil
    }

    private func runStaggeredWarmPreload(
        viewModel: MapViewModel,
        chatViewModel: ChatViewModel,
        accountTabVisible: Bool
    ) async {
        let warmStart = Date()
        print("[LaunchPerf] warmPreloadStart")

        await runWarmTask(name: "businessOwnerHydration", delayMs: 220) {
            await viewModel.runDeferredBusinessOwnerHydrationAfterLaunch()
        }
        guard !Task.isCancelled else { return }

        await runWarmTask(name: "lightweightUserPrefetch", delayMs: 180) {
            await viewModel.prefetchLightweightUserDataForStartup()
        }
        guard !Task.isCancelled else { return }

        await runWarmTask(name: "chatBadges", delayMs: 220) {
            let authenticated = await MainActor.run { viewModel.isAuthenticatedForSocialFeatures }
            if authenticated {
                await chatViewModel.refreshUnreadDirectMessageCount()
                await chatViewModel.refreshFriendRequestListsOnly()
#if DEBUG
                print("[StartupPrefetchDebug] unreadLoaded=true")
#endif
            } else {
                await MainActor.run {
                    chatViewModel.clearForSignOut()
                }
#if DEBUG
                print("[StartupPrefetchDebug] unreadLoaded=false")
#endif
            }
        }
        guard !Task.isCancelled else { return }

        await runWarmTask(name: "pokesBadge", delayMs: 160) {
            let canReceive = await MainActor.run { viewModel.canReceiveProfilePokes }
            guard canReceive else { return }
            await viewModel.refreshUnseenPokesBadgeIfNeeded()
        }
        guard !Task.isCancelled else { return }

        if accountTabVisible {
            print("[LaunchPerf] warmTask skipped name=suggestedFans reason=accountTabVisibleProfileIdentityCardOwnsLoad")
        }

        let totalMs = Int(Date().timeIntervalSince(warmStart) * 1000)
        print("[LaunchPerf] warmPreloadEnd ms=\(totalMs)")
    }

    private func runWarmTask(
        name: String,
        delayMs: UInt64,
        operation: () async -> Void
    ) async {
        if delayMs > 0 {
            do {
                try await Task.sleep(nanoseconds: delayMs * 1_000_000)
            } catch {
                return
            }
        }
        guard !Task.isCancelled else { return }

        let taskStart = Date()
        print("[LaunchPerf] warmTask start name=\(name)")
        await operation()
        let ms = Int(Date().timeIntervalSince(taskStart) * 1000)
        print("[LaunchPerf] warmTask end name=\(name) ms=\(ms)")
    }
}
