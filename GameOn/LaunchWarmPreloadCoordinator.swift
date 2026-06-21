import Foundation

/// Post-splash staggered preload for profile, chat, calendar, and social surfaces (does not block Discover first paint).
@MainActor
final class LaunchWarmPreloadCoordinator {
    static let shared = LaunchWarmPreloadCoordinator()

    private var preloadTask: Task<Void, Never>?
    private var lastCompletedSessionKey: String?

    private init() {}

    func beginIfNeeded(
        viewModel: MapViewModel,
        chatViewModel: ChatViewModel,
        accountTabVisible: Bool,
        forceRefresh: Bool = false
    ) {
        guard LaunchBootstrapState.didCompleteCriticalBootstrap else {
            print("[LaunchPerf] duplicateSkipped reason=criticalBootstrapIncomplete")
#if DEBUG
            print("[StartupPrefetchDebug] skippedReason=criticalBootstrapIncomplete")
#endif
            return
        }
        let sessionKey = warmPreloadSessionKey(viewModel: viewModel)
        if !forceRefresh, lastCompletedSessionKey == sessionKey {
#if DEBUG
            print("[StartupPrefetchDebug] skippedReason=sessionAlreadyWarm")
#endif
            return
        }
        guard forceRefresh || LaunchBootstrapState.markWarmPreloadStarted() else {
            print("[LaunchPerf] duplicateSkipped reason=warmPreloadAlreadyStarted")
#if DEBUG
            print("[StartupPrefetchDebug] skippedReason=warmPreloadAlreadyStarted")
#endif
            return
        }

        preloadTask?.cancel()
        preloadTask = Task(priority: .utility) { [weak viewModel, weak chatViewModel] in
            guard let viewModel, let chatViewModel else { return }
            await self.runStaggeredWarmPreload(
                viewModel: viewModel,
                chatViewModel: chatViewModel,
                accountTabVisible: accountTabVisible,
                sessionKey: sessionKey
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
        accountTabVisible: Bool,
        sessionKey: String
    ) async {
        let warmStart = Date()
        print("[LaunchPerf] warmPreloadStart")
#if DEBUG
        print("[StartupPrefetchDebug] start")
        print("[StartupPrefetchDebug] tier=0 task=criticalBootstrap cacheHit=true")
#endif

        await runWarmTask(tier: 1, name: "businessOwnerHydration", delayMs: 120) {
            await viewModel.runDeferredBusinessOwnerHydrationAfterLaunch()
        }
        guard !Task.isCancelled else { return }

        await runTier1Prefetch(viewModel: viewModel, chatViewModel: chatViewModel)
        guard !Task.isCancelled else { return }

        await runTier2Prefetch(viewModel: viewModel, chatViewModel: chatViewModel)
        guard !Task.isCancelled else { return }

        await runWarmTask(tier: 3, name: "regionalDiscoverWarmCache", delayMs: 520) {
            await viewModel.warmPreloadRegionalDiscoverCaches(chatViewModel: chatViewModel)
        }
        guard !Task.isCancelled else { return }

        await runWarmTask(tier: 2, name: "pokesBadge", delayMs: 120) {
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
#if DEBUG
        print("[StartupPrefetchDebug] durationMs=\(totalMs)")
#endif
        lastCompletedSessionKey = sessionKey
    }

    private func runTier1Prefetch(viewModel: MapViewModel, chatViewModel: ChatViewModel) async {
        guard !hasConfirmedSuspensionGate(viewModel: viewModel) else {
#if DEBUG
            print("[StartupPrefetchDebug] tier=1 task=all skippedReason=confirmedBan")
#endif
            return
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                await self.runWarmTask(tier: 1, name: "lightweightUserPrefetch", delayMs: 80) {
                    await viewModel.prefetchLightweightUserDataForStartup()
                }
            }
            group.addTask { @MainActor in
                await self.runWarmTask(tier: 1, name: "chatCounts", delayMs: 140) {
                    let authenticated = await MainActor.run { viewModel.isAuthenticatedForSocialFeatures }
                    if authenticated {
                        let chatResult = await chatViewModel.prefetchLightweightStartupChatData()
                        await chatViewModel.refreshFriendRequestListsOnly()
#if DEBUG
                        print("[StartupPrefetchDebug] task=chatCounts cacheHit=\(chatResult.skippedReason == "chatFreshCache")")
                        print("[StartupPrefetchDebug] skippedReason=\(chatResult.skippedReason ?? "none")")
#endif
                    } else {
                        await MainActor.run {
                            chatViewModel.clearForSignOut()
                        }
#if DEBUG
                        print("[StartupPrefetchDebug] task=chatCounts skippedReason=notAuthenticatedForChat")
#endif
                    }
                }
            }
            group.addTask { @MainActor in
                await self.runWarmTask(tier: 1, name: "goingSummaryCounts", delayMs: 200) {
                    guard viewModel.isAuthenticatedForSocialFeatures else {
#if DEBUG
                        print("[StartupPrefetchDebug] task=goingSummaryCounts skippedReason=notAuthenticated")
#endif
                        return
                    }
                    await viewModel.refreshFollowingTodayVenueEventPlansLightweight()
                    if viewModel.canFanUsePickupGamesUI {
                        await viewModel.loadPendingPickupGameJoinRequestCountForCreator(resyncRealtimeSubscription: false)
                        await viewModel.loadIncomingPickupGameInvites()
                        await viewModel.ensurePickupInviteRealtimeIfNeeded()
                    }
                }
            }
        }
    }

    private func runTier2Prefetch(viewModel: MapViewModel, chatViewModel: ChatViewModel) async {
        guard !hasConfirmedSuspensionGate(viewModel: viewModel) else {
#if DEBUG
            print("[StartupPrefetchDebug] tier=2 task=all skippedReason=confirmedBan")
#endif
            return
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                await self.runWarmTask(tier: 2, name: "chatInboxAndFriends", delayMs: 120) {
                    guard viewModel.isAuthenticatedForSocialFeatures else {
#if DEBUG
                        print("[StartupPrefetchDebug] task=chatInboxAndFriends skippedReason=notAuthenticated")
#endif
                        return
                    }
                    await chatViewModel.loadIfNeeded()
                }
            }
            group.addTask { @MainActor in
                await self.runWarmTask(tier: 2, name: "goingLists", delayMs: 260) {
                    guard viewModel.isAuthenticatedForSocialFeatures, viewModel.canUseFollowingTab else {
#if DEBUG
                        print("[StartupPrefetchDebug] task=goingLists skippedReason=notAllowed")
#endif
                        return
                    }
                    await viewModel.refreshFollowingTabDataGloballyUnlessFresh()
                    if viewModel.canFanUsePickupGamesUI {
                        await viewModel.loadMyPickupGameJoinRequestsForFollowing(reason: "startupPrefetch")
                        await viewModel.loadMyPickupGamesForSettings()
                        await viewModel.loadIncomingPickupGameInvites()
                        await viewModel.ensurePickupInviteRealtimeIfNeeded()
                    }
                }
            }
            group.addTask { @MainActor in
                await self.runWarmTask(tier: 2, name: "discoverVenueWarmCache", delayMs: 420) {
                    let hasDiscoverCache = await MainActor.run { !viewModel.bars.isEmpty }
                    if hasDiscoverCache {
#if DEBUG
                        print("[StartupPrefetchDebug] task=discoverVenueWarmCache cacheHit=true")
#endif
                        return
                    }
                    await viewModel.refreshDiscoverCoreInBackground()
                }
            }
        }

        await runWarmTask(tier: 2, name: "liveMatchesWarmCache", delayMs: 120) {
            await viewModel.refreshLiveMatchesForLiveTab(forceRefresh: false)
        }
    }

    private func runWarmTask(
        tier: Int,
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
#if DEBUG
        print("[StartupPrefetchDebug] tier=\(tier)")
        print("[StartupPrefetchDebug] task=\(name)")
#endif
        await operation()
        if Task.isCancelled {
#if DEBUG
            print("[StartupPrefetchDebug] cancelled=true")
            print("[StartupPrefetchDebug] task=\(name)")
#endif
            return
        }
        let ms = Int(Date().timeIntervalSince(taskStart) * 1000)
        print("[LaunchPerf] warmTask end name=\(name) ms=\(ms)")
#if DEBUG
        print("[StartupPrefetchDebug] durationMs=\(ms)")
#endif
    }

    private func warmPreloadSessionKey(viewModel: MapViewModel) -> String {
        if let id = viewModel.currentUserAuthId {
            return "\(viewModel.isVenueOwnerLoggedIn ? "business" : "fan"):\(id.uuidString.lowercased())"
        }
        let email = viewModel.currentUserEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !email.isEmpty {
            return "\(viewModel.isVenueOwnerLoggedIn ? "business" : "fan-email"):\(email)"
        }
        return "guest"
    }

    private func hasConfirmedSuspensionGate(viewModel: MapViewModel) -> Bool {
        if viewModel.activeAccountBan != nil { return true }
        if viewModel.activeBusinessAccountBan != nil,
           viewModel.isBusinessBanGatePresented
            || viewModel.hasAuthenticatedVenueOwnerSession
            || viewModel.currentUserIsBusinessAccount
            || viewModel.venueOwnerMode {
            return true
        }
        return false
    }
}
