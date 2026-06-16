import Foundation

/// Wall-clock + monotonic timestamps for correlating DM latency logs across phases.
///
/// **Interpretation**
/// - ``wall``: ISO8601 device wall clock (fractional seconds). Useful for rough cross-device ordering; clocks may skew.
/// - ``monoBootSec``: `ProcessInfo.processInfo.systemUptime` — reliable **same-device** deltas between log lines.
enum DMRealtimeDiagnostics {
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Lightweight DM realtime trace kept in all builds so TestFlight/device-console runs can verify subscriptions.
    static func debug(_ fields: String) {
        let wall = isoFormatter.string(from: Date())
        print("[DMRealtimeDebug] \(fields) wall=\(wall)")
    }

    /// Extra key=value fields only; prefix and timestamps are added automatically.
    static func log(_ fields: String) {
#if DEBUG
        let wall = isoFormatter.string(from: Date())
        let mono = ProcessInfo.processInfo.systemUptime
        print("[DMRealtimeDiag] \(fields) wall=\(wall) monoBootSec=\(String(format: "%.3f", mono))")
#endif
    }
}

enum RealtimeHealthDiagnostics {
    static func log(_ fields: String) {
#if DEBUG
        print("[RealtimeHealthDebug] \(fields)")
#endif
    }
}
