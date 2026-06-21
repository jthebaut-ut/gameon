import Foundation
import os

/// Cross-isolation debug logging gate (safe from actors and background threads).
nonisolated enum DebugLogGate {
    /// Keep noisy non-realtime diagnostics hidden while investigating realtime latency.
    static let noisyRealtimeInvestigationLogs = false

    /// When true, enables hot-path perf/image tracing in Release builds (off by default).
    static let releaseHotPathPerfLogging = false

    static var hotPathPerfLoggingEnabled: Bool {
#if DEBUG
        return true
#else
        return releaseHotPathPerfLogging
#endif
    }

    /// DEBUG by default; suppressed in Release unless ``releaseHotPathPerfLogging`` is enabled.
    static func hotPathPerf(_ log: @autoclosure () -> String) {
#if DEBUG
        print(log())
#else
        guard releaseHotPathPerfLogging else { return }
        print(log())
#endif
    }

    /// DEBUG-only diagnostic (stripped in Release); use for hot-path perf/realtime tracing.
    static func debug(_ log: @autoclosure () -> String) {
#if DEBUG
        print(log())
#endif
    }

    static func noisy(_ log: @autoclosure () -> String) {
#if DEBUG
        guard noisyRealtimeInvestigationLogs else { return }
        print(log())
#endif
    }
}

/// Tab / screen performance tracing (`[AppPerfDebug]`); DEBUG unless ``DebugLogGate/releaseHotPathPerfLogging``.
enum AppPerfDebug {
    private static let imageLoadLock = NSLock()
    private static var imageLoadCount = 0
    private static var imageCacheHitCount = 0

    static func tabSwitchStart(tab: String, from: String?, cacheHit: Bool, source: String) {
        guard DebugLogGate.hotPathPerfLoggingEnabled else { return }
        print("[AppPerfDebug] tabSwitchStart=\(Date().timeIntervalSince1970)")
        print("[AppPerfDebug] tab=\(tab)")
        print("[AppPerfDebug] cacheHit=\(cacheHit)")
        print("[AppPerfDebug] source=\(source)")
        if let from, !from.isEmpty {
            print("[AppPerfDebug] fromTab=\(from)")
        }
    }

    static func tabSwitchEnd(tab: String, durationMs: Int, cacheHit: Bool, source: String = "firstPaint") {
        guard DebugLogGate.hotPathPerfLoggingEnabled else { return }
        print("[AppPerfDebug] tabSwitchEnd=\(Date().timeIntervalSince1970)")
        print("[AppPerfDebug] tab=\(tab)")
        print("[AppPerfDebug] durationMs=\(durationMs)")
        print("[AppPerfDebug] cacheHit=\(cacheHit)")
        print("[AppPerfDebug] source=\(source)")
    }

    static func screenLoadStart(tab: String, source: String) {
        guard DebugLogGate.hotPathPerfLoggingEnabled else { return }
        print("[AppPerfDebug] screenLoadStart=\(Date().timeIntervalSince1970)")
        print("[AppPerfDebug] tab=\(tab)")
        print("[AppPerfDebug] source=\(source)")
    }

    static func networkFetchStarted(tab: String? = nil, source: String) {
        guard DebugLogGate.hotPathPerfLoggingEnabled else { return }
        if let tab {
            print("[AppPerfDebug] networkFetchStarted=true tab=\(tab) source=\(source)")
        } else {
            print("[AppPerfDebug] networkFetchStarted=true source=\(source)")
        }
    }

    static func networkFetchFinished(
        tab: String? = nil,
        source: String,
        durationMs: Int,
        cacheHit: Bool = false
    ) {
        guard DebugLogGate.hotPathPerfLoggingEnabled else { return }
        if let tab {
            print("[AppPerfDebug] networkFetchFinished=true tab=\(tab) source=\(source) durationMs=\(durationMs) cacheHit=\(cacheHit)")
        } else {
            print("[AppPerfDebug] networkFetchFinished=true source=\(source) durationMs=\(durationMs) cacheHit=\(cacheHit)")
        }
    }

    static func mainActorBlocked(ms: Double, tab: String? = nil, source: String) {
        guard DebugLogGate.hotPathPerfLoggingEnabled else { return }
        let rounded = Int(ms.rounded())
        Perf.mainActorWork(name: source, durationMs: rounded)
        if let tab {
            print("[AppPerfDebug] mainActorBlockedMs=\(rounded) tab=\(tab) source=\(source)")
        } else {
            print("[AppPerfDebug] mainActorBlockedMs=\(rounded) source=\(source)")
        }
    }

    static func imageLoad(cacheHit: Bool, source: String = "DiscoverMapImageCache") {
        guard DebugLogGate.hotPathPerfLoggingEnabled else { return }
        imageLoadLock.lock()
        imageLoadCount += 1
        if cacheHit { imageCacheHitCount += 1 }
        let total = imageLoadCount
        let hits = imageCacheHitCount
        imageLoadLock.unlock()
        print("[AppPerfDebug] imageLoadCount=\(total) cacheHit=\(cacheHit) source=\(source) cacheHits=\(hits)")
    }

    static func realtimeRestarted(_ restarted: Bool, source: String) {
        guard DebugLogGate.hotPathPerfLoggingEnabled else { return }
        print("[AppPerfDebug] realtimeRestarted=\(restarted) source=\(source)")
    }

    static func deferredWork(tab: String, work: String, source: String) {
        guard DebugLogGate.hotPathPerfLoggingEnabled else { return }
        print("[AppPerfDebug] deferredWork=true tab=\(tab) work=\(work) source=\(source)")
    }

    static func refreshSkipped(tab: String, source: String, reason: String) {
        guard DebugLogGate.hotPathPerfLoggingEnabled else { return }
        print("[AppPerfDebug] refreshSkipped=true tab=\(tab) source=\(source) reason=\(reason)")
    }
}

/// Main-tab switch tracing (`[TabPerf]`); DEBUG unless ``DebugLogGate/releaseHotPathPerfLogging``.
enum TabPerf {
    static func selectedTab(_ tab: String) {
        guard DebugLogGate.hotPathPerfLoggingEnabled else { return }
        print("[TabPerf] selectedTab=\(tab)")
    }

    static func tabSwitchStarted(from: String? = nil, to: String? = nil) {
        guard DebugLogGate.hotPathPerfLoggingEnabled else { return }
        if let from, let to {
            print("[TabPerf] tabSwitchStarted from=\(from) to=\(to)")
        } else {
            print("[TabPerf] tabSwitchStarted")
        }
    }

    static func tabSwitchRendered(tab: String, durationMs: Int? = nil) {
        guard DebugLogGate.hotPathPerfLoggingEnabled else { return }
        if let durationMs {
            print("[TabPerf] tabSwitchRendered tab=\(tab) durationMs=\(durationMs)")
        } else {
            print("[TabPerf] tabSwitchRendered tab=\(tab)")
        }
    }

    static func refreshSkipped(name: String, reason: String) {
        guard DebugLogGate.hotPathPerfLoggingEnabled else { return }
        print("[TabPerf] refreshSkipped reason=\(reason) name=\(name)")
    }

    static func refreshStarted(name: String) {
        guard DebugLogGate.hotPathPerfLoggingEnabled else { return }
        print("[TabPerf] refreshStarted name=\(name)")
    }

    static func refreshFinished(name: String, durationMs: Int) {
        guard DebugLogGate.hotPathPerfLoggingEnabled else { return }
        print("[TabPerf] refreshFinished name=\(name) durationMs=\(durationMs)")
    }

    static func duplicateRefreshCoalesced(name: String) {
        guard DebugLogGate.hotPathPerfLoggingEnabled else { return }
        print("[TabPerf] duplicateRefreshCoalesced name=\(name)")
    }
}

/// General performance tracing (`[Perf]`); DEBUG unless ``DebugLogGate/releaseHotPathPerfLogging``.
enum Perf {
    static func mainActorWork(name: String, durationMs: Int) {
        guard DebugLogGate.hotPathPerfLoggingEnabled else { return }
        print("[Perf] mainActorWork name=\(name) durationMs=\(durationMs)")
    }

    static func backgroundWork(name: String, durationMs: Int) {
        guard DebugLogGate.hotPathPerfLoggingEnabled else { return }
        print("[Perf] backgroundWork name=\(name) durationMs=\(durationMs)")
    }

    static func publishedWriteSkipped(name: String, reason: String) {
        guard DebugLogGate.hotPathPerfLoggingEnabled else { return }
        print("[Perf] publishedWriteSkipped name=\(name) reason=\(reason)")
    }

    static func duplicateTaskCoalesced(name: String) {
        guard DebugLogGate.hotPathPerfLoggingEnabled else { return }
        print("[Perf] duplicateTaskCoalesced name=\(name)")
    }

    static func cacheHit(name: String, detail: String = "") {
        guard DebugLogGate.hotPathPerfLoggingEnabled else { return }
        if detail.isEmpty {
            print("[Perf] cacheHit name=\(name)")
        } else {
            print("[Perf] cacheHit name=\(name) detail=\(detail)")
        }
    }
}

/// Image-cache performance tracing; callable from any isolation context (`[Perf]`).
nonisolated enum PerformanceLog {
    static func imageCacheHit(urlHash: String) {
        DebugLogGate.hotPathPerf("[Perf] imageCacheHit urlHash=\(urlHash)")
    }

    static func imageCacheMiss(urlHash: String) {
        DebugLogGate.hotPathPerf("[Perf] imageCacheMiss urlHash=\(urlHash)")
    }

    /// Short stable hash for log lines (not cryptographic).
    static func urlHash(for cacheKey: String) -> String {
        var hash: UInt64 = 5381
        for byte in cacheKey.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return String(format: "%016llx", hash)
    }
}

/// Going tab first-paint and background refresh tracing (`[GoingPerfDebug]`).
nonisolated enum GoingPerfDebug {
    static func screenAppear(source: String) {
        guard DebugLogGate.hotPathPerfLoggingEnabled else { return }
        print("[GoingPerfDebug] screenAppear=\(Date().timeIntervalSince1970)")
        print("[GoingPerfDebug] source=\(source)")
    }

    static func firstPaint(
        ms: Int,
        usedCachedData: Bool,
        savedGamesCount: Int,
        favoriteTeamGamesCount: Int,
        source: String
    ) {
        guard DebugLogGate.hotPathPerfLoggingEnabled else { return }
        print("[GoingPerfDebug] firstPaintMs=\(ms)")
        print("[GoingPerfDebug] usedCachedData=\(usedCachedData)")
        print("[GoingPerfDebug] savedGamesCount=\(savedGamesCount)")
        print("[GoingPerfDebug] favoriteTeamGamesCount=\(favoriteTeamGamesCount)")
        print("[GoingPerfDebug] source=\(source)")
    }

    static func refreshStarted(source: String) {
        guard DebugLogGate.hotPathPerfLoggingEnabled else { return }
        print("[GoingPerfDebug] refreshStarted=\(Date().timeIntervalSince1970)")
        print("[GoingPerfDebug] source=\(source)")
    }

    static func refreshFinished(source: String, durationMs: Int) {
        guard DebugLogGate.hotPathPerfLoggingEnabled else { return }
        print("[GoingPerfDebug] refreshFinished=\(Date().timeIntervalSince1970)")
        print("[GoingPerfDebug] refreshDurationMs=\(durationMs)")
        print("[GoingPerfDebug] source=\(source)")
    }

    static func duplicateRefreshSkipped(source: String, reason: String) {
        guard DebugLogGate.hotPathPerfLoggingEnabled else { return }
        print("[GoingPerfDebug] duplicateRefreshSkipped=true")
        print("[GoingPerfDebug] source=\(source)")
        print("[GoingPerfDebug] reason=\(reason)")
    }

    static func deferredWork(_ work: String, source: String) {
        guard DebugLogGate.hotPathPerfLoggingEnabled else { return }
        print("[GoingPerfDebug] deferredWork=\(work)")
        print("[GoingPerfDebug] source=\(source)")
    }
}

enum UIPerformanceDiagnostics {
    /// Profiling switch: temporarily set this to `true` to enable `[UIPerf]` logs and os_signpost events.
    static var uiPerformanceDiagnosticsEnabled = false

    private static let signpostLog = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "com.fangeo.ios",
        category: "UIPerf"
    )

    static func timestamp() -> CFAbsoluteTime {
        guard uiPerformanceDiagnosticsEnabled else { return 0 }
        return CFAbsoluteTimeGetCurrent()
    }

    static func elapsedMs(since start: CFAbsoluteTime) -> Double {
        guard uiPerformanceDiagnosticsEnabled else { return 0 }
        return (CFAbsoluteTimeGetCurrent() - start) * 1000
    }

    static func formattedMs(_ ms: Double) -> String {
        String(format: "%.1f", ms)
    }

    static func log(_ message: @autoclosure () -> String) {
        guard uiPerformanceDiagnosticsEnabled else { return }
        print("[UIPerf] \(message())")
    }

    static func signpost(_ name: StaticString, _ message: @autoclosure () -> String = "") {
        guard uiPerformanceDiagnosticsEnabled else { return }
        let message = message()
        if message.isEmpty {
            os_signpost(.event, log: signpostLog, name: name)
        } else {
            os_signpost(.event, log: signpostLog, name: name, "%{public}@", message)
        }
    }

    static func logDiscoverScrollFrameDropIfNeeded(elapsedMs: Double, source: String, eventId: String? = nil) {
        guard uiPerformanceDiagnosticsEnabled else { return }
        guard elapsedMs >= 16.7 else { return }
        let eventText = eventId.map { " eventId=\($0)" } ?? ""
        log("discoverScrollFrameDrop suspected=true source=\(source)\(eventText) ms=\(formattedMs(elapsedMs))")
    }
}
