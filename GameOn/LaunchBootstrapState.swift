import Foundation

/// Process-wide launch flags so splash bootstrap, timeout fallback, and warm preload do not duplicate work.
@MainActor
enum LaunchBootstrapState {
    private(set) static var didCompleteCriticalBootstrap = false
    private(set) static var didRunLaunchDiscoverCoreRefresh = false
    private(set) static var didStartWarmPreload = false
    private(set) static var didBecomeAppReady = false

    static func markCriticalBootstrapCompleted() {
        didCompleteCriticalBootstrap = true
    }

    static func markAppReady() {
        didBecomeAppReady = true
    }

    @discardableResult
    static func markLaunchDiscoverCoreRefreshStarted() -> Bool {
        guard !didRunLaunchDiscoverCoreRefresh else { return false }
        didRunLaunchDiscoverCoreRefresh = true
        return true
    }

    @discardableResult
    static func markWarmPreloadStarted() -> Bool {
        guard !didStartWarmPreload else { return false }
        didStartWarmPreload = true
        return true
    }

#if DEBUG
    static func resetForTesting() {
        didCompleteCriticalBootstrap = false
        didRunLaunchDiscoverCoreRefresh = false
        didStartWarmPreload = false
        didBecomeAppReady = false
    }
#endif
}
