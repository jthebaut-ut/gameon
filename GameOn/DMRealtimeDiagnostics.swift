import Foundation

/// Wall-clock + monotonic timestamps for correlating DM latency logs across phases (DEBUG only).
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

    /// Extra key=value fields only; prefix and timestamps are added automatically.
    static func log(_ fields: String) {
#if DEBUG
        let wall = isoFormatter.string(from: Date())
        let mono = ProcessInfo.processInfo.systemUptime
        print("[DMRealtimeDiag] \(fields) wall=\(wall) monoBootSec=\(String(format: "%.3f", mono))")
#endif
    }
}
