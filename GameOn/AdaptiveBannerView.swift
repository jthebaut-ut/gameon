import SwiftUI
import UIKit
import GoogleMobileAds

// MARK: - UIViewRepresentable

private struct AdaptiveBannerRepresentable: UIViewRepresentable {
    let adUnitID: String
    let adSize: AdSize
    let slotSize: CGSize
    let onAdLoaded: () -> Void
    let onAdFailed: (Error) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onAdLoaded: onAdLoaded, onAdFailed: onAdFailed)
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
        context.coordinator.attach(banner, in: container, adSize: adSize, slotSize: slotSize)
        context.coordinator.loadBannerIfNeeded(force: true)

        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.update(adSize: adSize, slotSize: slotSize, adUnitID: adUnitID)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject, BannerViewDelegate {
        private weak var banner: BannerView?
        private weak var container: UIView?
        private var widthConstraint: NSLayoutConstraint?
        private var heightConstraint: NSLayoutConstraint?
        private var currentAdSize: CGSize?
        private var currentSlotSize: CGSize?
        private var didRequestAd = false
        private let onAdLoaded: () -> Void
        private let onAdFailed: (Error) -> Void

        init(onAdLoaded: @escaping () -> Void, onAdFailed: @escaping (Error) -> Void) {
            self.onAdLoaded = onAdLoaded
            self.onAdFailed = onAdFailed
        }

        func attach(_ banner: BannerView, in container: UIView, adSize: AdSize, slotSize: CGSize) {
            self.banner = banner
            self.container = container
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
        }

        func update(adSize: AdSize, slotSize: CGSize, adUnitID: String) {
            guard let banner else { return }
            if banner.adUnitID != adUnitID {
                banner.adUnitID = adUnitID
                didRequestAd = false
            }

            let nextSize = adSize.size
            if currentAdSize != nextSize || currentSlotSize != slotSize {
                currentAdSize = nextSize
                currentSlotSize = slotSize
                banner.adSize = adSize
                widthConstraint?.constant = slotSize.width
                heightConstraint?.constant = slotSize.height
                container?.setNeedsLayout()
                loadBannerIfNeeded(force: true)
                return
            }

            loadBannerIfNeeded(force: false)
        }

        func loadBannerIfNeeded(force: Bool) {
            guard let banner else { return }
            if banner.rootViewController == nil {
                banner.rootViewController = AdMobRootViewController.topViewController()
            }
            guard force || !didRequestAd else { return }
            didRequestAd = true
            banner.load(Request())
        }

        func detach() {
            banner?.delegate = nil
            banner?.isHidden = true
            banner?.removeFromSuperview()
            banner = nil
            container = nil
            widthConstraint = nil
            heightConstraint = nil
        }

        func bannerViewDidReceiveAd(_ bannerView: BannerView) {
            onAdLoaded()
        }

        func bannerView(_ bannerView: BannerView, didFailToReceiveAdWithError error: Error) {
            onAdFailed(error)
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
    let adUnitID: String
    /// Final visible width available to the banner after parent screen margins.
    let layoutWidth: CGFloat
    var onAdLoaded: () -> Void = {}
    var onAdFailed: (Error) -> Void = { _ in }

    private var bannerSlotWidth: CGFloat {
        max(1, floor(layoutWidth))
    }

    private var adSize: AdSize {
        AdaptiveBannerLayout.anchoredAdSize(forBannerSlotWidth: bannerSlotWidth)
    }

    var body: some View {
        let slotSize = CGSize(width: bannerSlotWidth, height: adSize.size.height)
        AdaptiveBannerRepresentable(
            adUnitID: adUnitID,
            adSize: adSize,
            slotSize: slotSize,
            onAdLoaded: onAdLoaded,
            onAdFailed: onAdFailed
        )
        .frame(width: slotSize.width, height: slotSize.height)
        .clipped()
        .accessibilityElement(children: .contain)
    }
}
