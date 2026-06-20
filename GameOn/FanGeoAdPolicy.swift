import Foundation

// MARK: - Display mode (screenshot / marketing builds)

enum AdDisplayMode: String, Equatable {
    case normal
    case hiddenForScreenshots
}

// MARK: - Future ad-free entitlement (no StoreKit yet)

@MainActor
enum FanGeoUserEntitlements {
    /// Server-backed `user_profiles.ad_free_enabled`; defaults to false until profile load.
    private(set) static var adFreeEnabled = false

    static func apply(adFreeEnabled enabled: Bool) {
        adFreeEnabled = enabled
        FanGeoAdPolicy.logMountPolicy(source: "entitlementApply")
    }

    static func reset() {
        adFreeEnabled = false
        FanGeoAdPolicy.logMountPolicy(source: "entitlementReset")
    }
}

// MARK: - Central ad visibility policy

enum FanGeoAdPolicy {
    static let screenshotLaunchArgument = "--hide-ads-for-screenshots"
    static let screenshotModeUserDefaultsKey = "FanGeoAdDisplayModeHiddenForScreenshots"

    /// Set to `true` in Debug/Internal schemes to force screenshot mode without launch args.
    static let compileTimeScreenshotMode: Bool = {
#if FANGEO_HIDE_ADS_FOR_SCREENSHOTS
        true
#else
        false
#endif
    }()

    /// Screenshot mode is only available in Debug or TestFlight sandbox (internal) builds.
    static var isScreenshotModeEligibleBuild: Bool {
#if DEBUG
        true
#else
        AdDiagnostics.enabled
#endif
    }

    static var displayMode: AdDisplayMode {
        guard isScreenshotModeEligibleBuild else { return .normal }
        if compileTimeScreenshotMode { return .hiddenForScreenshots }
        if ProcessInfo.processInfo.arguments.contains(screenshotLaunchArgument) {
            return .hiddenForScreenshots
        }
        if UserDefaults.standard.bool(forKey: screenshotModeUserDefaultsKey) {
            return .hiddenForScreenshots
        }
        return .normal
    }

    static var isScreenshotModeActive: Bool {
        displayMode == .hiddenForScreenshots
    }

    /// Settings toggle backing store; only effective when `isScreenshotModeEligibleBuild`.
    static var screenshotModeUserPreferenceEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: screenshotModeUserDefaultsKey) }
        set {
            guard isScreenshotModeEligibleBuild else { return }
            UserDefaults.standard.set(newValue, forKey: screenshotModeUserDefaultsKey)
        }
    }

    /// Reserved hook for future business-account ad policy.
    static func shouldSuppressForBusinessPolicy(isBusinessAccount: Bool) -> Bool {
        _ = isBusinessAccount
        return false
    }

    static var adsSuppressed: Bool {
        isScreenshotModeActive
            || FanGeoUserEntitlements.adFreeEnabled
            || shouldSuppressForBusinessPolicy(isBusinessAccount: false)
    }

    static var adsSuppressionReason: String? {
        if isScreenshotModeActive { return "screenshotMode" }
        if FanGeoUserEntitlements.adFreeEnabled { return "adFreeEntitlement" }
        if shouldSuppressForBusinessPolicy(isBusinessAccount: false) { return "businessPolicy" }
        return nil
    }

    /// Skip AdMob SDK bootstrap (no consent/UMP/MobileAds network start).
    static var shouldSkipAdNetworkBootstrap: Bool {
        isScreenshotModeActive
    }

    /// Omit in-feed / banner ad slots from list plans.
    static func shouldInsertAdsInFeeds(isBusinessAccount: Bool = false) -> Bool {
        guard !adsSuppressed else { return false }
        guard !shouldSuppressForBusinessPolicy(isBusinessAccount: isBusinessAccount) else { return false }
        return true
    }

    /// Policy gate for mounting ad views (screenshot / ad-free / placement). Consent is enforced at request time in UIKit hosts.
    static func shouldRenderAds(
        placementAllowed: Bool = true,
        consentAllowsAds: Bool = true,
        isBusinessAccount: Bool = false
    ) -> Bool {
        guard placementAllowed else { return false }
        guard shouldInsertAdsInFeeds(isBusinessAccount: isBusinessAccount) else { return false }
        guard consentAllowsAds else { return false }
        return true
    }

    /// Mount ad UI when policy allows; omit consent so hosts can register for consent-ready reload.
    static func shouldMountAdViews(placementAllowed: Bool = true, isBusinessAccount: Bool = false) -> Bool {
        shouldRenderAds(placementAllowed: placementAllowed, consentAllowsAds: true, isBusinessAccount: isBusinessAccount)
    }

    static func logMountPolicy(source: String = "policy") {
        guard AdDiagnostics.enabled else { return }
        print("[AdDebug] ad_free_enabled=\(FanGeoUserEntitlements.adFreeEnabled)")
        print("[AdDebug] shouldMountAdViews=\(shouldMountAdViews()) source=\(source)")
    }

    static func logStartupDiagnostics() {
        guard AdDiagnostics.enabled else { return }
        print("[AdDebug] adDisplayMode=\(displayMode.rawValue)")
        if let reason = adsSuppressionReason {
            print("[AdDebug] adsSuppressed=true reason=\(reason)")
        } else {
            print("[AdDebug] adsSuppressed=false")
        }
        print("[AdDebug] adFreeEnabled=\(FanGeoUserEntitlements.adFreeEnabled)")
        logMountPolicy(source: "startup")
    }
}
