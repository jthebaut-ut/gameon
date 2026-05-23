import SwiftUI
import UIKit
import GoogleMobileAds

// MARK: - UIViewRepresentable

private struct AdaptiveBannerRepresentable: UIViewRepresentable {
    let placement: String
    let adUnitID: String
    let adSize: AdSize
    let slotSize: CGSize
    let layoutWidth: CGFloat
    let onAdLoaded: () -> Void
    let onAdFailed: (Error) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            placement: placement,
            layoutWidth: layoutWidth,
            onAdLoaded: onAdLoaded,
            onAdFailed: onAdFailed
        )
    }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .clear
        container.clipsToBounds = true

        let banner = BannerView(adSize: adSize)
        banner.adUnitID = adUnitID
        banner.delegate = context.coordinator
        banner.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(banner)
        context.coordinator.attach(banner, in: container, adSize: adSize, slotSize: slotSize, adUnitID: adUnitID)

        AdDebugDiagnostics.logViewSnapshot(
            phase: "makeUIView",
            format: "banner",
            placement: placement,
            unitID: adUnitID,
            view: container,
            adSize: adSize.size,
            slotSize: slotSize,
            layoutWidth: layoutWidth,
            hostTabRaw: "discover"
        )

        context.coordinator.loadBannerIfNeeded(force: true, reason: "makeUIView")
        context.coordinator.logDiscoverAdVisibility(phase: "makeUIView.deferred")

        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.update(
            adSize: adSize,
            slotSize: slotSize,
            adUnitID: adUnitID,
            container: uiView
        )
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        AdDebugDiagnostics.logViewSnapshot(
            phase: "dismantle",
            format: "banner",
            placement: coordinator.placement,
            unitID: coordinator.lastAdUnitID,
            view: uiView,
            adSize: coordinator.currentAdSize,
            slotSize: coordinator.currentSlotSize,
            layoutWidth: coordinator.layoutWidth,
            hostTabRaw: "discover"
        )
        coordinator.detach()
    }

    final class Coordinator: NSObject, BannerViewDelegate {
        let placement: String
        let layoutWidth: CGFloat
        private weak var banner: BannerView?
        private weak var container: UIView?
        private var widthConstraint: NSLayoutConstraint?
        private var heightConstraint: NSLayoutConstraint?
        private(set) var currentAdSize: CGSize?
        private(set) var currentSlotSize: CGSize?
        private(set) var lastAdUnitID: String?
        private var didRequestAd = false
        private var requestStartedAt: Date?
        private let onAdLoaded: () -> Void
        private let onAdFailed: (Error) -> Void

        init(
            placement: String,
            layoutWidth: CGFloat,
            onAdLoaded: @escaping () -> Void,
            onAdFailed: @escaping (Error) -> Void
        ) {
            self.placement = placement
            self.layoutWidth = layoutWidth
            self.onAdLoaded = onAdLoaded
            self.onAdFailed = onAdFailed
        }

        func attach(_ banner: BannerView, in container: UIView, adSize: AdSize, slotSize: CGSize, adUnitID: String) {
            self.banner = banner
            self.container = container
            lastAdUnitID = adUnitID
            currentAdSize = adSize.size
            currentSlotSize = slotSize

            let width = banner.widthAnchor.constraint(equalToConstant: slotSize.width)
            let height = banner.heightAnchor.constraint(equalToConstant: slotSize.height)
            widthConstraint = width
            heightConstraint = height

            NSLayoutConstraint.activate([
                banner.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                banner.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                width,
                height
            ])
            logDiscoverAdState(phase: "attached", requested: false)
        }

        func update(adSize: AdSize, slotSize: CGSize, adUnitID: String, container: UIView) {
            guard let banner else { return }
            lastAdUnitID = adUnitID

            if banner.adUnitID != adUnitID {
                banner.adUnitID = adUnitID
                didRequestAd = false
                AdDebugDiagnostics.logEvent(
                    event: "unitIDChanged",
                    format: "banner",
                    placement: placement,
                    fields: ["unitID": adUnitID]
                )
            }

            let nextSize = adSize.size
            if currentAdSize != nextSize || currentSlotSize != slotSize {
                currentAdSize = nextSize
                currentSlotSize = slotSize
                banner.adSize = adSize
                widthConstraint?.constant = slotSize.width
                heightConstraint?.constant = slotSize.height
                container.setNeedsLayout()
                container.layoutIfNeeded()

                AdDebugDiagnostics.logViewSnapshot(
                    phase: "updateUIView.resize",
                    format: "banner",
                    placement: placement,
                    unitID: adUnitID,
                    view: container,
                    adSize: nextSize,
                    slotSize: slotSize,
                    layoutWidth: layoutWidth,
                    hostTabRaw: "discover",
                    extra: ["iPadInlineAdaptive": "\(UIDevice.current.userInterfaceIdiom == .pad)"]
                )

                loadBannerIfNeeded(force: true, reason: "adSizeOrSlotChanged")
                logDiscoverAdVisibility(phase: "updateUIView.resize.deferred")
                return
            }

            AdDebugDiagnostics.logViewSnapshot(
                phase: "updateUIView",
                format: "banner",
                placement: placement,
                unitID: adUnitID,
                view: container,
                adSize: nextSize,
                slotSize: slotSize,
                layoutWidth: layoutWidth,
                hostTabRaw: "discover"
            )
            loadBannerIfNeeded(force: false, reason: "updateUIView")
            logDiscoverAdVisibility(phase: "updateUIView.deferred")
        }

        func loadBannerIfNeeded(force: Bool, reason: String) {
            guard let banner else { return }
            guard isHostTabVisible else {
                logDiscoverAdState(phase: "hostTabHidden.deferRequest", requested: false)
                return
            }

            if banner.rootViewController == nil {
                banner.rootViewController = AdMobRootViewController.topViewController()
                if banner.rootViewController == nil {
                    AdDebugDiagnostics.logMissingRootViewController(
                        format: "banner",
                        placement: placement,
                        unitID: banner.adUnitID
                    )
                }
            }

            guard force || !didRequestAd else { return }

            AdDebugDiagnostics.logViewSnapshot(
                phase: "preRequest.\(reason)",
                format: "banner",
                placement: placement,
                unitID: banner.adUnitID,
                view: container,
                adSize: currentAdSize,
                slotSize: currentSlotSize,
                layoutWidth: layoutWidth,
                hostTabRaw: "discover",
                extra: ["force": "\(force)", "didRequestAd": "\(didRequestAd)"]
            )

            didRequestAd = true
            requestStartedAt = Date()
            logDiscoverAdState(phase: "request.\(reason)", requested: true)

            AdDebugDiagnostics.logRequestStart(
                format: "banner",
                placement: placement,
                unitID: banner.adUnitID ?? "unknown",
                adSize: currentAdSize,
                slotSize: currentSlotSize,
                layoutWidth: layoutWidth,
                extra: ["reason": reason, "loadTrigger": reason]
            )

            banner.load(Request())
            logDiscoverAdVisibility(phase: "request.\(reason).deferred")
        }

        private var isHostTabVisible: Bool {
            !AdDebugContext.isTabOffscreenPreserved(tabRaw: "discover")
        }

        func detach() {
            logDiscoverAdState(phase: "detach", requested: false)
            banner?.delegate = nil
            banner?.isHidden = true
            banner?.removeFromSuperview()
            banner = nil
            container = nil
            widthConstraint = nil
            heightConstraint = nil
            didRequestAd = false
            requestStartedAt = nil
        }

        func bannerViewDidReceiveAd(_ bannerView: BannerView) {
            guard isHostTabVisible else {
                logDiscoverAdState(phase: "loaded.hostTabHidden", requested: false, loaded: true)
                return
            }
            let elapsed = requestStartedAt.map { Date().timeIntervalSince($0) * 1000 }
            AdDebugDiagnostics.logResponseSuccess(
                format: "banner",
                placement: placement,
                unitID: bannerView.adUnitID,
                elapsedMs: elapsed,
                adSize: bannerView.adSize.size,
                slotSize: currentSlotSize
            )
            AdDebugDiagnostics.logViewSnapshot(
                phase: "didReceiveAd",
                format: "banner",
                placement: placement,
                unitID: bannerView.adUnitID,
                view: container,
                adSize: bannerView.adSize.size,
                slotSize: currentSlotSize,
                layoutWidth: layoutWidth,
                hostTabRaw: "discover"
            )
            logDiscoverAdState(phase: "loaded", requested: false, loaded: true)
            logDiscoverAdVisibility(phase: "loaded.deferred")
            onAdLoaded()
        }

        func bannerView(_ bannerView: BannerView, didFailToReceiveAdWithError error: Error) {
            guard isHostTabVisible else {
                logDiscoverAdState(phase: "failed.hostTabHidden", requested: false, failed: error.localizedDescription)
                return
            }
            let elapsed = requestStartedAt.map { Date().timeIntervalSince($0) * 1000 }
            AdDebugDiagnostics.logResponseFailure(
                format: "banner",
                placement: placement,
                unitID: bannerView.adUnitID,
                error: error,
                elapsedMs: elapsed
            )
            AdDebugDiagnostics.logViewSnapshot(
                phase: "didFailToReceiveAd",
                format: "banner",
                placement: placement,
                unitID: bannerView.adUnitID,
                view: container,
                adSize: bannerView.adSize.size,
                slotSize: currentSlotSize,
                layoutWidth: layoutWidth,
                hostTabRaw: "discover"
            )
            logDiscoverAdState(phase: "failed", requested: false, failed: error.localizedDescription)
            onAdFailed(error)
        }

        func bannerViewDidRecordImpression(_ bannerView: BannerView) {
            guard isHostTabVisible else {
                logDiscoverAdState(phase: "impression.hostTabHidden", requested: false)
                return
            }
            AdDebugDiagnostics.logEvent(
                event: "impressionRecorded",
                format: "banner",
                placement: placement,
                fields: ["unitID": bannerView.adUnitID ?? "unknown"]
            )
        }

        func logDiscoverAdVisibility(phase: String) {
            DispatchQueue.main.async { [weak self] in
                self?.logDiscoverAdState(phase: phase, requested: false)
            }
        }

        private func logDiscoverAdState(
            phase: String,
            requested: Bool,
            loaded: Bool = false,
            failed: String? = nil
        ) {
            guard placement == "discover.bottomStrip" else { return }
            let view = banner ?? container
            let frame = view?.frame ?? .zero
            let attached = view?.window != nil
            let visibleTab = isHostTabVisible
            let isHidden = view?.isHidden ?? true
            let alpha = view?.alpha ?? 0
            let unitID = banner?.adUnitID ?? lastAdUnitID ?? "unknown"
            print("[DiscoverAdDebug] phase=\(phase)")
            print("[DiscoverAdDebug] placement=\(placement)")
            print("[DiscoverAdDebug] unitID=\(unitID)")
            print("[DiscoverAdDebug] requested=\(requested)")
            print("[DiscoverAdDebug] loaded=\(loaded)")
            print("[DiscoverAdDebug] failed=\(failed ?? "nil")")
            print(String(format: "[DiscoverAdDebug] frame=%.1fx%.1f@%.1f,%.1f", frame.width, frame.height, frame.origin.x, frame.origin.y))
            print("[DiscoverAdDebug] attachedToWindow=\(attached)")
            print("[DiscoverAdDebug] visibleTab=\(visibleTab)")
            print("[DiscoverAdDebug] isHidden=\(isHidden)")
            print(String(format: "[DiscoverAdDebug] alpha=%.3f", alpha))
        }
    }
}

// MARK: - Layout helpers

enum AdaptiveBannerLayout {
    private static let compactMaxHeight: CGFloat = 50

    /// Width passed to Google's anchored adaptive API (points). Uses `currentOrientationAnchoredAdaptiveBanner`.
    static func anchoredAdSize(forBannerSlotWidth slotWidth: CGFloat) -> AdSize {
        let w = max(1, floor(slotWidth))
        return inlineAdaptiveBanner(width: w, maxHeight: compactMaxHeight)
    }

    /// Exact rendered size returned by Google's adaptive banner API for the available slot width.
    static func adaptiveBannerSize(forAvailableWidth availableWidth: CGFloat) -> CGSize {
        let width = max(1, floor(availableWidth))
        let adSize = anchoredAdSize(forBannerSlotWidth: width)
        return CGSize(width: width, height: adSize.size.height)
    }

    /// Vertical space to reserve for the banner (anchored adaptive height for the current orientation).
    static func reservedSlotHeight(forOuterLayoutWidth layoutWidth: CGFloat) -> CGFloat {
        adaptiveBannerSize(forAvailableWidth: layoutWidth).height
    }
}

/// Anchored adaptive AdMob banner sized to the exact parent slot.
struct AdaptiveBannerView: View {
    let placement: String
    let adUnitID: String
    /// Final visible width available to the banner after parent screen margins.
    let layoutWidth: CGFloat
    var onAdLoaded: () -> Void = {}
    var onAdFailed: (Error) -> Void = { _ in }

    init(
        placement: String = "discover.bottomStrip",
        adUnitID: String,
        layoutWidth: CGFloat,
        onAdLoaded: @escaping () -> Void = {},
        onAdFailed: @escaping (Error) -> Void = { _ in }
    ) {
        self.placement = placement
        self.adUnitID = adUnitID
        self.layoutWidth = layoutWidth
        self.onAdLoaded = onAdLoaded
        self.onAdFailed = onAdFailed
    }

    private var bannerSlotWidth: CGFloat {
        max(1, floor(layoutWidth))
    }

    private var adSize: AdSize {
        AdaptiveBannerLayout.anchoredAdSize(forBannerSlotWidth: bannerSlotWidth)
    }

    var body: some View {
        let slotSize = CGSize(width: bannerSlotWidth, height: adSize.size.height)
        GeometryReader { geo in
            AdaptiveBannerRepresentable(
                placement: placement,
                adUnitID: adUnitID,
                adSize: adSize,
                slotSize: slotSize,
                layoutWidth: layoutWidth,
                onAdLoaded: onAdLoaded,
                onAdFailed: onAdFailed
            )
            .onAppear {
                AdDebugDiagnostics.logSwiftUILayout(
                    format: "banner",
                    placement: placement,
                    proposedLayoutWidth: layoutWidth,
                    measuredWidth: geo.size.width,
                    measuredHeight: geo.size.height
                )
            }
            .onChange(of: geo.size.width) { _, measuredW in
                AdDebugDiagnostics.logSwiftUILayout(
                    format: "banner",
                    placement: placement,
                    proposedLayoutWidth: layoutWidth,
                    measuredWidth: measuredW,
                    measuredHeight: geo.size.height
                )
            }
        }
        .frame(width: slotSize.width, height: slotSize.height)
        .clipped()
        .accessibilityElement(children: .contain)
    }
}
