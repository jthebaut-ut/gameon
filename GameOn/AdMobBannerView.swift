import Foundation
import GoogleMobileAds
import UIKit

// MARK: - Ad unit configuration (test in DEBUG, production in RELEASE)

/// Central AdMob IDs for FanGeo.
enum AdMobConfiguration {
    // MARK: Test (Google sample app / units — DEBUG only)
    static let testApplicationID = "ca-app-pub-3940256099942544~1458002511"
    static let testBannerAdUnitID = "ca-app-pub-3940256099942544/2435281174"
    /// Google-provided native test unit.
    static let testNativeAdUnitID = "ca-app-pub-3940256099942544/3986624511"

    // MARK: Production
    static let productionApplicationID = "ca-app-pub-9637364906993742~5547329973"
    static let productionBannerAdUnitID = "ca-app-pub-9637364906993742/6964124517"
    static let productionNativeAdUnitID: String? = "ca-app-pub-9637364906993742/7885775201"

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
        let unit = usesTestAds ? testNativeAdUnitID : (productionNativeAdUnitID ?? testNativeAdUnitID)
        logUnitSelection(format: "native", unitID: unit)
        return unit
    }

    static var nativeAdsUseTemporaryTestUnitInRelease: Bool {
        !usesTestAds && productionNativeAdUnitID == nil
    }

    private static func logUnitSelection(format: String, unitID: String) {
        AdMobDiagnostics.logUnitSelection(format: format, unitID: unitID)
    }
}

enum AdMobDiagnostics {
    static func logBootstrap() {
        log("appIDLoadedFromPlist=\(loadedApplicationIDFromPlist() ?? "missing")")
        log("configuredApplicationID=\(AdMobConfiguration.applicationID)")
        log("usesTestAds=\(AdMobConfiguration.usesTestAds)")
        log("nativeUsesTemporaryTestUnitInRelease=\(AdMobConfiguration.nativeAdsUseTemporaryTestUnitInRelease)")
        log("nativeValidatorPopupEnabled=\(AdMobConfiguration.enableNativeAdValidatorPopup)")
    }

    static func logUnitSelection(format: String, unitID: String) {
        log("format=\(format) unitID=\(unitID) usesTestAds=\(AdMobConfiguration.usesTestAds)")
        if format == "native", AdMobConfiguration.nativeAdsUseTemporaryTestUnitInRelease {
            log("nativeReleaseMode=temporary_google_test_unit awaiting_real_production_native_unit")
        }
    }

    static func logLoadSuccess(format: String, unitID: String?) {
        log("loadSuccess format=\(format) unitID=\(unitID ?? "unknown")")
    }

    static func logLoadFailure(format: String, unitID: String?, error: Error) {
        let nsError = error as NSError
        let message = nsError.localizedDescription.replacingOccurrences(of: "\n", with: " ")
        log("loadFailure format=\(format) unitID=\(unitID ?? "unknown") domain=\(nsError.domain) code=\(nsError.code) message=\(message)")
    }

    static func logMissingRootViewController(format: String, unitID: String?) {
        log("rootViewControllerMissing format=\(format) unitID=\(unitID ?? "unknown")")
    }

    private static func loadedApplicationIDFromPlist() -> String? {
        Bundle.main.object(forInfoDictionaryKey: "GADApplicationIdentifier") as? String
    }

    private static func log(_ message: String) {
        print("[AdMobDiagnostics] \(message)")
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
        AdMobDiagnostics.logBootstrap()
        Task {
            _ = await MobileAds.shared.start()
        }
    }
}
