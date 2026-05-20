import SwiftUI

/// Timing for the static launch/loading screen visibility (isolated from bootstrap logic).
enum FanGeoSplashAnimation {
    static let minimumVisibleDuration: TimeInterval = 1.2
    static let statusRotationInterval: UInt64 = 1_500_000_000
}
