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

// MARK: - Deep AdMob diagnostics ([AdDebug] — always printed for TestFlight Console)

enum AdDebugDiagnostics {
    // MARK: Bootstrap / plist verification

    static func logBootstrap() {
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
                "attStatus": attStatusLabel(),
                "attPromptConfigured": "\(attPromptConfigured)"
            ]
        )

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

    static func logUnitSelection(format: String, unitID: String) {
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
            "visibleTab": AdDebugContext.visibleTab,
            "attStatus": attStatusLabel()
        ]
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
        slotSize: CGSize? = nil
    ) {
        var fields: [String: String] = [
            "unitID": unitID ?? "unknown",
            "fill": "success",
            "visibleTab": AdDebugContext.visibleTab,
            "attStatus": attStatusLabel()
        ]
        if let elapsedMs {
            fields["elapsedMs"] = String(format: "%.0f", elapsedMs)
        }
        if let adSize {
            fields["adSizeW"] = fmt(adSize.width)
            fields["adSizeH"] = fmt(adSize.height)
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
        elapsedMs: Double? = nil
    ) {
        var fields = gadErrorFields(error)
        fields["unitID"] = unitID ?? "unknown"
        fields["fill"] = "failure"
        fields["visibleTab"] = AdDebugContext.visibleTab
        fields["attStatus"] = attStatusLabel()
        if let elapsedMs {
            fields["elapsedMs"] = String(format: "%.0f", elapsedMs)
        }
        log(event: "responseFailure", format: format, placement: placement, fields: fields)
    }

    static func logMissingRootViewController(format: String, placement: String, unitID: String?) {
        log(
            event: "rootViewControllerMissing",
            format: format,
            placement: placement,
            fields: [
                "unitID": unitID ?? "unknown",
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
            "attStatus": attStatusLabel()
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

    // MARK: Internals

    private static func log(
        event: String,
        format: String,
        placement: String,
        fields: [String: String]
    ) {
        let sortedPairs = fields.sorted { $0.key < $1.key }
        let payload = sortedPairs.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        print("[AdDebug] event=\(event) format=\(format) placement=\(placement) \(payload)")
    }

    private static func gadErrorFields(_ error: Error) -> [String: String] {
        var fields: [String: String] = [:]
        let ns = error as NSError
        fields["errorDomain"] = ns.domain
        fields["errorCode"] = "\(ns.code)"
        fields["errorDescription"] = ns.localizedDescription
            .replacingOccurrences(of: "\n", with: " ")

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

    private static func attStatusLabel() -> String {
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
        String(format: "%.1f", value)
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
