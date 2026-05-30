import Foundation
import AppTrackingTransparency
import GoogleMobileAds
import UIKit
import UserMessagingPlatform

// Verbose ad diagnostics are limited to developer/internal builds; App Store users should not see ad debug logs.
enum AdDiagnostics {
    private static var didLogTestDeviceConfiguration = false

    static var enabled: Bool {
#if DEBUG
        return true
#else
        return sandboxReceiptURL?.lastPathComponent == "sandboxReceipt"
#endif
    }

    private static var sandboxReceiptURL: URL? {
        Bundle.main.value(forKey: "appStoreReceiptURL") as? URL
    }

    static func logStartupTestDeviceConfigurationIfNeeded() {
        guard enabled, !didLogTestDeviceConfiguration else { return }
        didLogTestDeviceConfiguration = true
        let identifiers = MobileAds.shared.requestConfiguration.testDeviceIdentifiers ?? []
        print("[AdDebug] testDeviceConfigured=\(!identifiers.isEmpty || AdMobConfiguration.usesTestAds) requestConfiguration.testDeviceIdentifiers=\(identifiers) testDeviceIdentifierCount=\(identifiers.count)")
    }
}

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
    private static let developerTestDeviceIdentifiers = [
        "5221eb346221e44cb542638866e39d10"
    ]

    static var usesTestAds: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    static var testDeviceIdentifiers: [String] {
        AdDiagnostics.enabled ? developerTestDeviceIdentifiers : []
    }

    static func configureRequestConfiguration() {
        MobileAds.shared.requestConfiguration.testDeviceIdentifiers = testDeviceIdentifiers
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

    static func bannerAdUnitID(for placement: String) -> String {
        let unit = shouldUseOfficialTestUnit(format: "banner", placement: placement)
            ? testBannerAdUnitID
            : productionBannerAdUnitID
        logUnitSelection(format: "banner", unitID: unit)
        return unit
    }

    static func nativeAdUnitID(for placement: String) -> String {
        let unit = shouldUseOfficialTestUnit(format: "native", placement: placement)
            ? testNativeAdUnitID
            : (productionNativeAdUnitID ?? testNativeAdUnitID)
        logUnitSelection(format: "native", unitID: unit)
        return unit
    }

    private static func shouldUseOfficialTestUnit(format: String, placement: String) -> Bool {
        guard AdDiagnostics.enabled else { return false }
        switch (format, placement) {
        case ("banner", "discover.bottomStrip"),
             ("native", "chat.inboxFeed"):
            return true
        default:
            return usesTestAds
        }
    }

    static var nativeAdsUseTemporaryTestUnitInRelease: Bool {
        !usesTestAds && productionNativeAdUnitID == nil
    }

    private static func logUnitSelection(format: String, unitID: String) {
        AdMobDiagnostics.logUnitSelection(format: format, unitID: unitID)
    }
}

enum AdRuntimeDevice {
    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    /// DEBUG builds use Google test ad units, which are safe on physical devices.
    static var testDeviceConfigured: Bool {
        AdMobConfiguration.usesTestAds || !AdMobConfiguration.testDeviceIdentifiers.isEmpty
    }
}

private enum FanGeoAdConsentPrePromptStore {
    private static let acknowledgedKey = "FanGeoAdConsentPrePromptAcknowledged"

    static var hasAcknowledged: Bool {
        UserDefaults.standard.bool(forKey: acknowledgedKey)
    }

    static func markAcknowledged() {
        UserDefaults.standard.set(true, forKey: acknowledgedKey)
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
@MainActor
enum GoogleMobileAdsBootstrap {
    private static var didStart = false
    private static var didFinishConsentFlow = false
    private static var adsCanBeRequested = false
    private static var didStartMobileAds = false
    private static var isWaitingForPreConsentPrompt = false
    private static var pendingReadyHandlers: [() -> Void] = []

    static var canRequestAds: Bool {
        didFinishConsentFlow && adsCanBeRequested
    }

    static var privacyOptionsRequired: Bool {
        ConsentInformation.shared.privacyOptionsRequirementStatus == .required
    }

    static var shouldPresentPreConsentPrompt: Bool {
        isWaitingForPreConsentPrompt && !FanGeoAdConsentPrePromptStore.hasAcknowledged
    }

    static func startIfNeeded() {
        guard !didStart else { return }
        didStart = true
        AdMobConfiguration.configureRequestConfiguration()
        AdDiagnostics.logStartupTestDeviceConfigurationIfNeeded()
        AdMobDiagnostics.logBootstrap()
        AdDebugDiagnostics.logConsent("attStatus=\(AdDebugDiagnostics.currentATTStatusLabel())")
        guard FanGeoAdConsentPrePromptStore.hasAcknowledged else {
            isWaitingForPreConsentPrompt = true
            AdDebugDiagnostics.logConsent("preConsentPromptRequired=true")
            return
        }
        continueConsentFlowAfterPrePrompt()
    }

    static func acknowledgePreConsentPromptAndContinue() {
        FanGeoAdConsentPrePromptStore.markAcknowledged()
        guard isWaitingForPreConsentPrompt || !didFinishConsentFlow else { return }
        isWaitingForPreConsentPrompt = false
        AdDebugDiagnostics.logConsent("preConsentPromptAcknowledged=true")
        continueConsentFlowAfterPrePrompt()
    }

    private static func continueConsentFlowAfterPrePrompt() {
        Task {
            await resolveConsentAndStartAdsIfAllowed()
        }
    }

    static func runWhenAdsCanBeRequested(_ handler: @escaping () -> Void) {
        if canRequestAds {
            handler()
            return
        }
        pendingReadyHandlers.append(handler)
    }

    static func presentPrivacyOptionsIfRequired() async {
        guard privacyOptionsRequired,
              let root = await waitForRootViewController(timeoutSeconds: 3) else { return }
        await presentPrivacyOptions(from: root)
    }

    private static func resolveConsentAndStartAdsIfAllowed() async {
        await updateUMPConsentInformation()
        await loadAndPresentUMPFormIfNeeded()
        await requestATTIfAppropriate()

        adsCanBeRequested = ConsentInformation.shared.canRequestAds
        didFinishConsentFlow = true
        AdDebugDiagnostics.logConsent("canRequestAds=\(adsCanBeRequested)")

        if adsCanBeRequested {
            await startMobileAdsIfNeeded()
        }

        let handlers = pendingReadyHandlers
        pendingReadyHandlers.removeAll()
        handlers.forEach { $0() }
    }

    private static func updateUMPConsentInformation() async {
        AdDebugDiagnostics.logConsent("umpUpdateStarted=true")
        let parameters = RequestParameters()
        await withCheckedContinuation { continuation in
            ConsentInformation.shared.requestConsentInfoUpdate(with: parameters) { error in
                if let error {
                    AdDebugDiagnostics.logConsent("umpUpdateFailed=\(error.localizedDescription)")
                }
                continuation.resume()
            }
        }
        let required = ConsentInformation.shared.consentStatus == .required
        AdDebugDiagnostics.logConsent("consentRequired=\(required)")
    }

    private static func loadAndPresentUMPFormIfNeeded() async {
        guard let root = await waitForRootViewController(timeoutSeconds: 3) else {
            AdDebugDiagnostics.logConsent("umpFormSkipped=noRootViewController")
            return
        }
        await withCheckedContinuation { continuation in
            ConsentForm.loadAndPresentIfRequired(from: root) { error in
                if let error {
                    AdDebugDiagnostics.logConsent("umpFormFailed=\(error.localizedDescription)")
                }
                continuation.resume()
            }
        }
    }

    private static func requestATTIfAppropriate() async {
        guard #available(iOS 14, *) else {
            AdDebugDiagnostics.logConsent("attStatus=unavailable_pre_iOS14")
            return
        }
        guard ATTrackingManager.trackingAuthorizationStatus == .notDetermined else {
            AdDebugDiagnostics.logConsent("attStatus=\(AdDebugDiagnostics.currentATTStatusLabel())")
            return
        }
        await withCheckedContinuation { continuation in
            ATTrackingManager.requestTrackingAuthorization { _ in
                Task { @MainActor in
                    AdDebugDiagnostics.logConsent("attStatus=\(AdDebugDiagnostics.currentATTStatusLabel())")
                    continuation.resume()
                }
            }
        }
    }

    private static func startMobileAdsIfNeeded() async {
        guard !didStartMobileAds else { return }
        didStartMobileAds = true
        _ = await MobileAds.shared.start()
        AdDebugDiagnostics.logConsent("adsStarted=true")
        AdDebugDiagnostics.logSDKStartCompleted()
    }

    private static func waitForRootViewController(timeoutSeconds: TimeInterval) async -> UIViewController? {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let root = AdMobRootViewController.topViewController() {
                return root
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return AdMobRootViewController.topViewController()
    }

    private static func presentPrivacyOptions(from root: UIViewController) async {
        await withCheckedContinuation { continuation in
            ConsentForm.presentPrivacyOptionsForm(from: root) { error in
                if let error {
                    AdDebugDiagnostics.logConsent("privacyOptionsFailed=\(error.localizedDescription)")
                }
                continuation.resume()
            }
        }
    }
}
