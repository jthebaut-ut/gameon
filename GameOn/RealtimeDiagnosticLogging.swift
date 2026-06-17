import Foundation
import os

enum DebugLogGate {
    /// Keep noisy non-realtime diagnostics hidden while investigating realtime latency.
    static let noisyRealtimeInvestigationLogs = false

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

/// Always-on tab / screen performance tracing (`[AppPerfDebug]`).
enum AppPerfDebug {
    private static let imageLoadLock = NSLock()
    private static var imageLoadCount = 0
    private static var imageCacheHitCount = 0

    static func tabSwitchStart(tab: String, from: String?, cacheHit: Bool, source: String) {
        print("[AppPerfDebug] tabSwitchStart=\(Date().timeIntervalSince1970)")
        print("[AppPerfDebug] tab=\(tab)")
        print("[AppPerfDebug] cacheHit=\(cacheHit)")
        print("[AppPerfDebug] source=\(source)")
        if let from, !from.isEmpty {
            print("[AppPerfDebug] fromTab=\(from)")
        }
    }

    static func tabSwitchEnd(tab: String, durationMs: Int, cacheHit: Bool, source: String = "firstPaint") {
        print("[AppPerfDebug] tabSwitchEnd=\(Date().timeIntervalSince1970)")
        print("[AppPerfDebug] tab=\(tab)")
        print("[AppPerfDebug] durationMs=\(durationMs)")
        print("[AppPerfDebug] cacheHit=\(cacheHit)")
        print("[AppPerfDebug] source=\(source)")
    }

    static func screenLoadStart(tab: String, source: String) {
        print("[AppPerfDebug] screenLoadStart=\(Date().timeIntervalSince1970)")
        print("[AppPerfDebug] tab=\(tab)")
        print("[AppPerfDebug] source=\(source)")
    }

    static func networkFetchStarted(tab: String? = nil, source: String) {
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
        if let tab {
            print("[AppPerfDebug] networkFetchFinished=true tab=\(tab) source=\(source) durationMs=\(durationMs) cacheHit=\(cacheHit)")
        } else {
            print("[AppPerfDebug] networkFetchFinished=true source=\(source) durationMs=\(durationMs) cacheHit=\(cacheHit)")
        }
    }

    static func mainActorBlocked(ms: Double, tab: String? = nil, source: String) {
        let rounded = Int(ms.rounded())
        if let tab {
            print("[AppPerfDebug] mainActorBlockedMs=\(rounded) tab=\(tab) source=\(source)")
        } else {
            print("[AppPerfDebug] mainActorBlockedMs=\(rounded) source=\(source)")
        }
    }

    static func imageLoad(cacheHit: Bool, source: String = "DiscoverMapImageCache") {
        imageLoadLock.lock()
        imageLoadCount += 1
        if cacheHit { imageCacheHitCount += 1 }
        let total = imageLoadCount
        let hits = imageCacheHitCount
        imageLoadLock.unlock()
        print("[AppPerfDebug] imageLoadCount=\(total) cacheHit=\(cacheHit) source=\(source) cacheHits=\(hits)")
    }

    static func realtimeRestarted(_ restarted: Bool, source: String) {
        print("[AppPerfDebug] realtimeRestarted=\(restarted) source=\(source)")
    }

    static func deferredWork(tab: String, work: String, source: String) {
        print("[AppPerfDebug] deferredWork=true tab=\(tab) work=\(work) source=\(source)")
    }

    static func refreshSkipped(tab: String, source: String, reason: String) {
        print("[AppPerfDebug] refreshSkipped=true tab=\(tab) source=\(source) reason=\(reason)")
    }
}

/// Going tab first-paint and background refresh tracing (`[GoingPerfDebug]`).
nonisolated enum GoingPerfDebug {
    static func screenAppear(source: String) {
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
        print("[GoingPerfDebug] firstPaintMs=\(ms)")
        print("[GoingPerfDebug] usedCachedData=\(usedCachedData)")
        print("[GoingPerfDebug] savedGamesCount=\(savedGamesCount)")
        print("[GoingPerfDebug] favoriteTeamGamesCount=\(favoriteTeamGamesCount)")
        print("[GoingPerfDebug] source=\(source)")
    }

    static func refreshStarted(source: String) {
        print("[GoingPerfDebug] refreshStarted=\(Date().timeIntervalSince1970)")
        print("[GoingPerfDebug] source=\(source)")
    }

    static func refreshFinished(source: String, durationMs: Int) {
        print("[GoingPerfDebug] refreshFinished=\(Date().timeIntervalSince1970)")
        print("[GoingPerfDebug] refreshDurationMs=\(durationMs)")
        print("[GoingPerfDebug] source=\(source)")
    }

    static func duplicateRefreshSkipped(source: String, reason: String) {
        print("[GoingPerfDebug] duplicateRefreshSkipped=true")
        print("[GoingPerfDebug] source=\(source)")
        print("[GoingPerfDebug] reason=\(reason)")
    }

    static func deferredWork(_ work: String, source: String) {
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
