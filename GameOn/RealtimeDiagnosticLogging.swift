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

enum UIPerformanceDiagnostics {
    /// Manually flip to `true` during a profiling run to enable `[UIPerf]` logs and os_signpost events.
    static var uiPerformanceDiagnosticsEnabled = false

    private static let signpostLog = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "com.fangeo.ios",
        category: "UIPerf"
    )

    static func timestamp() -> CFAbsoluteTime {
        CFAbsoluteTimeGetCurrent()
    }

    static func elapsedMs(since start: CFAbsoluteTime) -> Double {
        (CFAbsoluteTimeGetCurrent() - start) * 1000
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
        guard elapsedMs >= 16.7 else { return }
        let eventText = eventId.map { " eventId=\($0)" } ?? ""
        log("discoverScrollFrameDrop suspected=true source=\(source)\(eventText) ms=\(formattedMs(elapsedMs))")
    }
}
