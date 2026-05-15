import Foundation
import GoogleMobileAds

/// AdMob test configuration only. Production IDs exist in AdMob but must not be used until explicitly switched in Info.plist and here.
enum AdMobTestConfiguration {
    static let testApplicationID = "ca-app-pub-3940256099942544~1458002511"
    static let testBannerAdUnitID = "ca-app-pub-3940256099942544/2435281174"

    // Production (enable only when intentionally going live):
    // static let productionApplicationID = "ca-app-pub-9637364906993742~5547329973"
    // static let productionBannerAdUnitID = "ca-app-pub-9637364906993742/6964124517"
}

/// Initializes the Google Mobile Ads SDK once at launch (non-blocking).
enum GoogleMobileAdsBootstrap {
    static func startIfNeeded() {
        Task {
            _ = await MobileAds.shared.start()
        }
    }
}
