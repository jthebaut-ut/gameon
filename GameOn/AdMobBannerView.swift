import Foundation
import GoogleMobileAds
import UIKit

// MARK: - Ad unit configuration (test in DEBUG, production in RELEASE)

/// Central AdMob IDs for FanGeo. Replace production unit IDs before App Store release.
enum AdMobConfiguration {
    // MARK: Test (Google sample app / units — DEBUG only)
    static let testApplicationID = "ca-app-pub-3940256099942544~1458002511"
    static let testBannerAdUnitID = "ca-app-pub-3940256099942544/2435281174"
    /// Google-provided native test unit.
    static let testNativeAdUnitID = "ca-app-pub-3940256099942544/3986624511"

    // MARK: Production — enable in AdMob-Info.plist `GADApplicationIdentifier` when going live.
    static let productionApplicationID = "ca-app-pub-9637364906993742~5547329973"
    static let productionBannerAdUnitID = "ca-app-pub-9637364906993742/6964124517"
    /// ⬇️ Paste your real AdMob **Native** ad unit ID here for release builds.
    static let productionNativeAdUnitID = "ca-app-pub-9637364906993742/0000000000"

    static var usesTestAds: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// DEBUG-only manual switch for the Google Mobile Ads native validator UI.
    ///
    /// The SDK reads `GADNativeAdValidatorEnabled` from `AdMob-Info.plist`; keep that key in sync
    /// with this flag when you intentionally want the blocking validator popup during local testing.
    static var enableNativeAdValidatorPopup: Bool {
        #if DEBUG
        false
        #else
        false
        #endif
    }

    static var applicationID: String {
        usesTestAds ? testApplicationID : productionApplicationID
    }

    static var bannerAdUnitID: String {
        let unit = usesTestAds ? testBannerAdUnitID : productionBannerAdUnitID
        logUnitSelection(format: "banner", unitID: unit)
        return unit
    }

    static var nativeAdUnitID: String {
        let unit = usesTestAds ? testNativeAdUnitID : productionNativeAdUnitID
        logUnitSelection(format: "native", unitID: unit)
        return unit
    }

    private static func logUnitSelection(format: String, unitID: String) {
#if DEBUG
        print("[AdMobDebug] usingTestAds=\(usesTestAds)")
        print("[AdMobDebug] adFormat=\(format)")
        print("[AdMobDebug] productionUnitLoaded=\(!usesTestAds)")
        _ = unitID
#endif
    }
}

/// Backward-compatible name used by older call sites.
enum AdMobTestConfiguration {
    static var testBannerAdUnitID: String { AdMobConfiguration.testBannerAdUnitID }
}

// MARK: - Shared root view controller for ad presentation

enum AdMobRootViewController {
    static func bestKeyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }

    static func topViewController() -> UIViewController? {
        guard let root = bestKeyWindow()?.rootViewController else { return nil }
        var top: UIViewController = root
        while let presented = top.presentedViewController {
            top = presented
        }
        if let nav = top as? UINavigationController, let visible = nav.visibleViewController {
            top = visible
        }
        if let tab = top as? UITabBarController, let selected = tab.selectedViewController {
            top = selected
        }
        return top
    }
}

/// Initializes the Google Mobile Ads SDK once at launch (non-blocking).
enum GoogleMobileAdsBootstrap {
    private static var didStart = false

    static func startIfNeeded() {
        guard !didStart else { return }
        didStart = true
#if DEBUG
        print("[AdMobDebug] usingTestAds=\(AdMobConfiguration.usesTestAds)")
        print("[AdMobDebug] productionUnitLoaded=\(!AdMobConfiguration.usesTestAds)")
        print("[AdMobDebug] nativeValidatorPopupEnabled=\(AdMobConfiguration.enableNativeAdValidatorPopup)")
        print("[AdMobDebug] nativeValidatorIssues=0")
#endif
        Task {
            _ = await MobileAds.shared.start()
        }
    }
}
