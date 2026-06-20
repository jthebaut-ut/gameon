import AdSupport
import AppTrackingTransparency
import Foundation
import GoogleMobileAds
import UIKit

// MARK: - Runtime context (visible tab for lifecycle / lazy-mount diagnosis)

enum AdDebugContext {
    private(set) static var visibleTabRaw: String = "unknown"

    @MainActor
    static func setVisibleTab(_ raw: String) {
        visibleTabRaw = raw
        AdDebugDiagnostics.logEvent(
            event: "visibleTabChanged",
            format: "context",
            placement: "mainTabs",
            fields: ["tab": raw]
        )
    }

    static var visibleTab: String { visibleTabRaw }

    /// True when the host tab is preserved off-screen (`preservedRoot` opacity 0).
    static func isTabOffscreenPreserved(tabRaw: String) -> Bool {
        visibleTabRaw != tabRaw
    }
}

// MARK: - Deep AdMob diagnostics ([AdDebug] — quiet by default; enable `AdDiagnostics.enabled` for ad debugging)

enum AdDebugDiagnostics {
    private static var loggedUnitSelectionKeys: Set<String> = []
    private static var loggedEventOnceKeys: Set<String> = []

    enum AdLoadFailedReason: String {
        case noFill = "no_fill"
        case network
        case consentNotReady = "consent_not_ready"
        case rootViewControllerMissing = "root_view_controller_missing"
        case configurationIssue = "configuration_issue"
        case unknown
    }

    // MARK: Bootstrap / plist verification

    static func logBootstrap() {
        guard AdDiagnostics.enabled else { return }
        let plistAppID = Bundle.main.object(forInfoDictionaryKey: "GADApplicationIdentifier") as? String
        let configuredAppID = AdMobConfiguration.applicationID
        let skItems = Bundle.main.object(forInfoDictionaryKey: "SKAdNetworkItems") as? [[String: Any]]
        let skCount = skItems?.count ?? 0
        let idfa = ASIdentifierManager.shared().advertisingIdentifier.uuidString
        let attPromptKey = "NSUserTrackingUsageDescription"
        let attPromptConfigured = Bundle.main.object(forInfoDictionaryKey: attPromptKey) != nil

        log(
            event: "bootstrap",
            format: "sdk",
            placement: "appLaunch",
            fields: [
                "plistGADApplicationIdentifier": plistAppID ?? "missing",
                "configuredApplicationID": configuredAppID,
                "appIDMatch": "\(plistAppID == configuredAppID)",
                "usesTestAds": "\(AdMobConfiguration.usesTestAds)",
                "adDisplayMode": FanGeoAdPolicy.displayMode.rawValue,
                "adsSuppressed": "\(FanGeoAdPolicy.adsSuppressed)",
                "adFreeEnabled": "\(FanGeoUserEntitlements.adFreeEnabled)",
                "testDeviceConfigured": "\(AdRuntimeDevice.testDeviceConfigured)",
                "testDeviceIdentifierCount": "\(AdMobConfiguration.testDeviceIdentifiers.count)",
                "deviceIsPhysical": "\(!AdRuntimeDevice.isSimulator)",
                "buildIsDebug": buildIsDebugDescription(),
                "bannerUnit": AdMobConfiguration.bannerAdUnitID,
                "nativeUnit": AdMobConfiguration.nativeAdUnitID,
                "nativeReleaseUsesTestFallback": "\(AdMobConfiguration.nativeAdsUseTemporaryTestUnitInRelease)",
                "SKAdNetworkItemsPresent": "\(skItems != nil)",
                "SKAdNetworkItemsCount": "\(skCount)",
                "interstitialConfigured": "false",
                "deviceModel": UIDevice.current.model,
                "userInterfaceIdiom": idiomLabel(UIDevice.current.userInterfaceIdiom),
                "systemVersion": UIDevice.current.systemVersion,
                "idfa": idfa,
                "attStatus": currentATTStatusLabel(),
                "attPromptConfigured": "\(attPromptConfigured)"
            ]
        )

        print("[AdDebug] appIDMatch=\(plistAppID == configuredAppID)")
        print("[AdDebug] usesTestAds=\(AdMobConfiguration.usesTestAds)")
        print("[AdDebug] buildIsDebug=\(buildIsDebugDescription())")
        print("[AdDebug] adDisplayMode=\(FanGeoAdPolicy.displayMode.rawValue)")
        if let reason = FanGeoAdPolicy.adsSuppressionReason {
            print("[AdDebug] adsSuppressed=true reason=\(reason)")
        } else {
            print("[AdDebug] adsSuppressed=false")
        }

        if skCount == 0 {
            log(
                event: "bootstrapWarning",
                format: "sdk",
                placement: "appLaunch",
                fields: ["reason": "SKAdNetworkItems missing or empty — may reduce fill on iOS 14+"]
            )
        }
        if plistAppID != configuredAppID {
            log(
                event: "bootstrapWarning",
                format: "sdk",
                placement: "appLaunch",
                fields: [
                    "reason": "GADApplicationIdentifier plist value differs from AdMobConfiguration.applicationID",
                    "plist": plistAppID ?? "nil",
                    "configured": configuredAppID
                ]
            )
        }
    }

    static func logSDKStartCompleted() {
        log(event: "sdkStartCompleted", format: "sdk", placement: "appLaunch", fields: [:])
    }

    static func logConsent(_ message: String) {
        guard AdDiagnostics.enabled else { return }
        print("[AdConsentDebug] \(message)")
    }

    /// Discover map bottom banner decision + lifecycle (`[AdDebug] placement=discoverMapBanner`).
    static func logDiscoverMapBanner(
        phase: String,
        placementAllowed: Bool = true,
        consentAllowsAds: Bool? = nil,
        adViewCreated: Bool? = nil,
        adLoadStarted: Bool? = nil,
        adLoadSucceeded: Bool? = nil,
        adLoadFailed: Bool? = nil,
        extra: [String: String] = [:]
    ) {
        guard AdDiagnostics.enabled else { return }
        let consent = consentAllowsAds ?? GoogleMobileAdsBootstrap.canRequestAds
        let shouldRender = FanGeoAdPolicy.shouldMountAdViews(placementAllowed: placementAllowed)
        print("[AdDebug] placement=discoverMapBanner phase=\(phase)")
        print("[AdDebug] adDisplayMode=\(FanGeoAdPolicy.displayMode.rawValue)")
        print("[AdDebug] screenshotMode=\(FanGeoAdPolicy.isScreenshotModeActive)")
        print("[AdDebug] adFree=\(FanGeoUserEntitlements.adFreeEnabled)")
        print("[AdDebug] consentAllowsAds=\(consent)")
        print("[AdDebug] placementAllowed=\(placementAllowed)")
        print("[AdDebug] shouldRenderAds=\(shouldRender)")
        if let adViewCreated { print("[AdDebug] adViewCreated=\(adViewCreated)") }
        if let adLoadStarted { print("[AdDebug] adLoadStarted=\(adLoadStarted)") }
        if let adLoadSucceeded { print("[AdDebug] adLoadSucceeded=\(adLoadSucceeded)") }
        if let adLoadFailed { print("[AdDebug] adLoadFailed=\(adLoadFailed)") }
        for (key, value) in extra.sorted(by: { $0.key < $1.key }) {
            print("[AdDebug] \(key)=\(value)")
        }
    }

    static func logUnitSelection(format: String, unitID: String) {
        let key = "\(format)|\(unitID)|\(AdMobConfiguration.usesTestAds)"
        guard loggedUnitSelectionKeys.insert(key).inserted else { return }
        log(
            event: "unitSelected",
            format: format,
            placement: "configuration",
            fields: [
                "unitID": unitID,
                "usesTestAds": "\(AdMobConfiguration.usesTestAds)"
            ]
        )
    }

    // MARK: Request lifecycle

    static func logRequestStart(
        format: String,
        placement: String,
        unitID: String,
        adSize: CGSize?,
        slotSize: CGSize?,
        layoutWidth: CGFloat?,
        extra: [String: String] = [:]
    ) {
        var fields: [String: String] = [
            "unitID": unitID,
            "requestStarted": "true",
            "visibleTab": AdDebugContext.visibleTab,
            "attStatus": currentATTStatusLabel()
        ]
        fields.merge(runtimeTestDeviceFields()) { _, new in new }
        if let adSize {
            fields["adSizeW"] = fmt(adSize.width)
            fields["adSizeH"] = fmt(adSize.height)
        }
        if let slotSize {
            fields["slotW"] = fmt(slotSize.width)
            fields["slotH"] = fmt(slotSize.height)
        }
        if let layoutWidth {
            fields["layoutWidth"] = fmt(layoutWidth)
            if layoutWidth <= 0 {
                fields["zeroLayoutWidth"] = "true"
            }
        }
        if let adSize, adSize.width <= 0 {
            fields["zeroAdWidth"] = "true"
        }
        fields.merge(extra) { _, new in new }
        log(event: "requestStart", format: format, placement: placement, fields: fields)
    }

    static func logResponseSuccess(
        format: String,
        placement: String,
        unitID: String?,
        elapsedMs: Double?,
        adSize: CGSize? = nil,
        slotSize: CGSize? = nil,
        responseInfo: ResponseInfo? = nil
    ) {
        var fields: [String: String] = [
            "unitID": unitID ?? "unknown",
            "fill": "success",
            "requestSuccess": "true",
            "visibleTab": AdDebugContext.visibleTab,
            "attStatus": currentATTStatusLabel()
        ]
        fields.merge(runtimeTestDeviceFields()) { _, new in new }
        fields.merge(responseInfoFields(responseInfo)) { _, new in new }
        if let elapsedMs {
            fields["elapsedMs"] = String(format: "%.0f", elapsedMs)
        }
        if let adSize {
            fields["adSizeW"] = fmt(adSize.width)
            fields["adSizeH"] = fmt(adSize.height)
            fields["loadedAdSize"] = "\(fmt(adSize.width))x\(fmt(adSize.height))"
        }
        if let slotSize {
            fields["slotW"] = fmt(slotSize.width)
            fields["slotH"] = fmt(slotSize.height)
        }
        log(event: "responseSuccess", format: format, placement: placement, fields: fields)
    }

    static func logResponseFailure(
        format: String,
        placement: String,
        unitID: String?,
        error: Error,
        elapsedMs: Double? = nil,
        responseInfo: ResponseInfo? = nil
    ) {
        var fields = gadErrorFields(error)
        let reason = classifyAdLoadFailure(error)
        fields["unitID"] = unitID ?? "unknown"
        fields["fill"] = "failure"
        fields["requestFailed"] = "true"
        fields["loadFailedReason"] = reason.rawValue
        fields["visibleTab"] = AdDebugContext.visibleTab
        fields["attStatus"] = currentATTStatusLabel()
        fields.merge(runtimeTestDeviceFields()) { _, new in new }
        fields.merge(responseInfoFields(responseInfo)) { _, new in new }
        if let elapsedMs {
            fields["elapsedMs"] = String(format: "%.0f", elapsedMs)
        }
        log(event: "responseFailure", format: format, placement: placement, fields: fields)
    }

    static func logRequestDeferred(
        format: String,
        placement: String,
        unitID: String?,
        reason: AdLoadFailedReason,
        message: String
    ) {
        log(
            event: "requestDeferred",
            format: format,
            placement: placement,
            fields: [
                "unitID": unitID ?? "unknown",
                "loadFailedReason": reason.rawValue,
                "errorCode": "n/a",
                "errorMessage": message,
                "visibleTab": AdDebugContext.visibleTab,
                "attStatus": currentATTStatusLabel()
            ]
        )
    }

    static func logCollapsedAdSpace(format: String, placement: String, unitID: String?, error: Error) {
        let reason = classifyAdLoadFailure(error)
        var fields = gadErrorFields(error)
        fields["unitID"] = unitID ?? "unknown"
        fields["loadFailedReason"] = reason.rawValue
        fields["collapsedNoFill"] = "\(reason == .noFill)"
        log(event: "adSpaceCollapsed", format: format, placement: placement, fields: fields)
    }

    static func logRequestSuppressed(
        format: String,
        placement: String,
        unitID: String?,
        reason: String,
        fields extraFields: [String: String] = [:]
    ) {
        var fields = extraFields
        fields["unitID"] = unitID ?? "unknown"
        fields["reason"] = reason
        log(event: "requestSuppressed", format: format, placement: placement, fields: fields)
    }

    static func logRetryScheduled(
        format: String,
        placement: String,
        unitID: String?,
        delaySeconds: TimeInterval,
        retryBackoffCount: Int,
        failureReason: AdLoadFailedReason
    ) {
        log(
            event: "retryScheduled",
            format: format,
            placement: placement,
            fields: [
                "unitID": unitID ?? "unknown",
                "delaySeconds": String(format: "%.0f", delaySeconds),
                "retryBackoffCount": "\(retryBackoffCount)",
                "loadFailedReason": failureReason.rawValue
            ]
        )
    }

    static func logAdLoaded(format: String, placement: String, unitID: String?) {
        log(
            event: "adLoaded",
            format: format,
            placement: placement,
            fields: ["unitID": unitID ?? "unknown"]
        )
    }

    static func logConsentBecameReadyReload(format: String, placement: String, unitID: String?) {
        log(
            event: "consentReadyReload",
            format: format,
            placement: placement,
            fields: [
                "unitID": unitID ?? "unknown",
                "consentBecameReadyReload": "true",
                "visibleTab": AdDebugContext.visibleTab
            ]
        )
    }

    static func logMissingRootViewController(format: String, placement: String, unitID: String?) {
        log(
            event: "rootViewControllerMissing",
            format: format,
            placement: placement,
            fields: [
                "unitID": unitID ?? "unknown",
                "loadFailedReason": AdLoadFailedReason.rootViewControllerMissing.rawValue,
                "errorCode": "n/a",
                "errorMessage": "Root view controller is missing.",
                "visibleTab": AdDebugContext.visibleTab,
                "keyWindowPresent": "\(AdMobRootViewController.bestKeyWindow() != nil)"
            ]
        )
    }

    // MARK: View / layout / visibility

    static func logViewSnapshot(
        phase: String,
        format: String,
        placement: String,
        unitID: String?,
        view: UIView?,
        adSize: CGSize?,
        slotSize: CGSize?,
        layoutWidth: CGFloat?,
        hostTabRaw: String? = nil,
        extra: [String: String] = [:]
    ) {
        let hostTab = hostTabRaw ?? AdDebugContext.visibleTab
        let tabOffscreen = hostTabRaw.map { AdDebugContext.isTabOffscreenPreserved(tabRaw: $0) } ?? false

        var fields: [String: String] = [
            "phase": phase,
            "unitID": unitID ?? "unknown",
            "visibleTab": AdDebugContext.visibleTab,
            "hostTab": hostTab,
            "hostTabOffscreenPreserved": "\(tabOffscreen)",
            "attStatus": currentATTStatusLabel()
        ]

        if let view {
            let bounds = view.bounds
            let frameInWindow = view.window.map { view.convert(view.bounds, to: $0) }
            fields["frameW"] = fmt(bounds.width)
            fields["frameH"] = fmt(bounds.height)
            if let frameInWindow {
                fields["windowFrameW"] = fmt(frameInWindow.width)
                fields["windowFrameH"] = fmt(frameInWindow.height)
            }
            fields["attachedToWindow"] = "\(view.window != nil)"
            fields["isHidden"] = "\(view.isHidden)"
            fields["alpha"] = fmt(view.alpha)
            fields["windowAlpha"] = fmt(view.window?.alpha ?? 1)
            let zeroWidth = bounds.width <= 0.5
            fields["zeroFrameWidth"] = "\(zeroWidth)"
            if zeroWidth {
                fields["zeroFrameWidthWarning"] = "true"
            }
            let hiddenOrOffscreen = view.window == nil
                || view.isHidden
                || view.alpha < 0.01
                || tabOffscreen
                || zeroWidth
            fields["requestedWhileHiddenOrOffscreen"] = "\(hiddenOrOffscreen)"
        } else {
            fields["view"] = "nil"
        }

        if let adSize {
            fields["adSizeW"] = fmt(adSize.width)
            fields["adSizeH"] = fmt(adSize.height)
        }
        if let slotSize {
            fields["slotW"] = fmt(slotSize.width)
            fields["slotH"] = fmt(slotSize.height)
        }
        if let layoutWidth {
            fields["layoutWidth"] = fmt(layoutWidth)
            if layoutWidth <= 0 {
                fields["zeroLayoutWidth"] = "true"
            }
        }

        fields.merge(extra) { _, new in new }
        log(event: "viewSnapshot", format: format, placement: placement, fields: fields)
    }

    static func logSwiftUILayout(
        format: String,
        placement: String,
        proposedLayoutWidth: CGFloat,
        measuredWidth: CGFloat,
        measuredHeight: CGFloat
    ) {
        let mismatch = abs(proposedLayoutWidth - measuredWidth) > 1
        log(
            event: "swiftUILayout",
            format: format,
            placement: placement,
            fields: [
                "proposedLayoutWidth": fmt(proposedLayoutWidth),
                "measuredW": fmt(measuredWidth),
                "measuredH": fmt(measuredHeight),
                "geometryMismatch": "\(mismatch)",
                "zeroMeasuredWidth": "\(measuredWidth <= 0.5)",
                "visibleTab": AdDebugContext.visibleTab
            ]
        )
    }

    static func logInterstitialNotImplemented(placement: String) {
        log(
            event: "interstitialSkipped",
            format: "interstitial",
            placement: placement,
            fields: ["reason": "notImplementedInApp"]
        )
    }

    static func logEvent(
        event: String,
        format: String,
        placement: String,
        fields: [String: String] = [:]
    ) {
        log(event: event, format: format, placement: placement, fields: fields)
    }

    static func logEventOnce(
        event: String,
        format: String,
        placement: String,
        dedupeKey: String,
        fields: [String: String] = [:]
    ) {
        let key = "\(event)|\(format)|\(placement)|\(dedupeKey)"
        guard loggedEventOnceKeys.insert(key).inserted else { return }
        log(event: event, format: format, placement: placement, fields: fields)
    }

    // MARK: Internals

    private static func log(
        event: String,
        format: String,
        placement: String,
        fields: [String: String]
    ) {
        guard AdDiagnostics.enabled else { return }
        let sortedPairs = fields.sorted { $0.key < $1.key }
        let payload = sortedPairs.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        print("[AdDebug] event=\(event) format=\(format) placement=\(placement) \(payload)")
    }

    private static func gadErrorFields(_ error: Error) -> [String: String] {
        var fields: [String: String] = [:]
        let ns = error as NSError
        let errorMessage = ns.localizedDescription
            .replacingOccurrences(of: "\n", with: " ")
        fields["errorDomain"] = ns.domain
        fields["errorCode"] = "\(ns.code)"
        fields["errorDescription"] = errorMessage
        fields["errorMessage"] = errorMessage

        if let reason = ns.localizedFailureReason {
            fields["failureReason"] = reason.replacingOccurrences(of: "\n", with: " ")
        }
        if let recovery = ns.localizedRecoverySuggestion {
            fields["recoverySuggestion"] = recovery.replacingOccurrences(of: "\n", with: " ")
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            fields["underlyingDomain"] = underlying.domain
            fields["underlyingCode"] = "\(underlying.code)"
            fields["underlyingDescription"] = underlying.localizedDescription
        }
        for (key, value) in ns.userInfo where key != NSUnderlyingErrorKey {
            let rendered: String
            if let nested = value as? NSError {
                rendered = "\(nested.domain)/\(nested.code)"
            } else {
                rendered = "\(value)".replacingOccurrences(of: "\n", with: " ")
            }
            fields["userInfo.\(key)"] = String(rendered.prefix(280))
        }
        return fields
    }

    private static func runtimeTestDeviceFields() -> [String: String] {
        let identifiers = MobileAds.shared.requestConfiguration.testDeviceIdentifiers ?? []
        return [
            "isTestDevice": "\(AdRuntimeDevice.testDeviceConfigured)",
            "testDeviceIdentifiersCount": "\(identifiers.count)",
            "requestConfiguration.testDeviceIdentifiers": identifiers.isEmpty ? "[]" : identifiers.joined(separator: ",")
        ]
    }

    private static func responseInfoFields(_ responseInfo: ResponseInfo?) -> [String: String] {
        guard let responseInfo else {
            return [
                "responseInfo.responseIdentifier": "nil",
                "mediationAdapterClassName": "nil"
            ]
        }
        return [
            "responseInfo.responseIdentifier": responseInfo.responseIdentifier ?? "nil",
            "mediationAdapterClassName": responseInfo.loadedAdNetworkResponseInfo?.adNetworkClassName ?? "nil"
        ]
    }

    static func loadFailedReason(for error: Error) -> AdLoadFailedReason {
        classifyAdLoadFailure(error)
    }

    private static func classifyAdLoadFailure(_ error: Error) -> AdLoadFailedReason {
        let ns = error as NSError
        let text = [
            ns.domain,
            ns.localizedDescription,
            ns.localizedFailureReason ?? "",
            ns.localizedRecoverySuggestion ?? "",
            (ns.userInfo[NSUnderlyingErrorKey] as? NSError)?.localizedDescription ?? ""
        ]
        .joined(separator: " ")
        .lowercased()

        if text.contains("root view controller") {
            return .rootViewControllerMissing
        }
        if text.contains("no fill") || text.contains("no ad to show") || text.contains("no ad") {
            return .noFill
        }
        if ns.code == 1 && text.contains("google") {
            return .noFill
        }
        if ns.code == 2
            || text.contains("network")
            || text.contains("internet")
            || text.contains("connection")
            || text.contains("timed out")
            || text.contains("timeout") {
            return .network
        }
        if ns.code == 0
            || ns.code == 8
            || ns.code == 10
            || ns.code == 12
            || text.contains("invalid request")
            || text.contains("invalid ad")
            || text.contains("ad unit")
            || text.contains("application identifier")
            || text.contains("configured") {
            return .configurationIssue
        }
        return .unknown
    }

    static func currentATTStatusLabel() -> String {
        if #available(iOS 14, *) {
            switch ATTrackingManager.trackingAuthorizationStatus {
            case .notDetermined: return "notDetermined"
            case .restricted: return "restricted"
            case .denied: return "denied"
            case .authorized: return "authorized"
            @unknown default: return "unknown"
            }
        }
        return "unavailable_pre_iOS14"
    }

    private static func buildIsDebugDescription() -> String {
        #if DEBUG
        "true"
        #else
        "false"
        #endif
    }

    private static func idiomLabel(_ idiom: UIUserInterfaceIdiom) -> String {
        switch idiom {
        case .pad: return "pad"
        case .phone: return "phone"
        case .mac: return "mac"
        case .tv: return "tv"
        case .carPlay: return "carPlay"
        case .vision: return "vision"
        default: return "other"
        }
    }

    private static func fmt(_ value: CGFloat) -> String {
        String(format: "%.1f", Double(value))
    }
}

/// Legacy shim — routes to `[AdDebug]` logging.
enum AdMobDiagnostics {
    static func logBootstrap() {
        AdDebugDiagnostics.logBootstrap()
    }

    static func logUnitSelection(format: String, unitID: String) {
        AdDebugDiagnostics.logUnitSelection(format: format, unitID: unitID)
    }

    static func logLoadSuccess(format: String, unitID: String?) {
        AdDebugDiagnostics.logResponseSuccess(
            format: format,
            placement: "legacy",
            unitID: unitID,
            elapsedMs: nil
        )
    }

    static func logLoadFailure(format: String, unitID: String?, error: Error) {
        AdDebugDiagnostics.logResponseFailure(
            format: format,
            placement: "legacy",
            unitID: unitID,
            error: error
        )
    }

    static func logMissingRootViewController(format: String, unitID: String?) {
        AdDebugDiagnostics.logMissingRootViewController(
            format: format,
            placement: "legacy",
            unitID: unitID
        )
    }
}
