import SwiftUI
import UIKit
import GoogleMobileAds

// MARK: - UIKit bridge (root VC for ad load)

private enum AdaptiveBannerRootViewController {
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

// MARK: - UIViewRepresentable

private struct AdaptiveBannerRepresentable: UIViewRepresentable {
    let adUnitID: String
    let adSize: AdSize
    let onAdLoaded: () -> Void
    let onAdFailed: (Error) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onAdLoaded: onAdLoaded, onAdFailed: onAdFailed)
    }

    func makeUIView(context: Context) -> BannerView {
        let banner = BannerView(adSize: adSize)
        banner.adUnitID = adUnitID
        banner.delegate = context.coordinator
        context.coordinator.attach(banner)

        DispatchQueue.main.async {
            if banner.rootViewController == nil {
                banner.rootViewController = AdaptiveBannerRootViewController.topViewController()
            }
            banner.load(Request())
        }

        return banner
    }

    func updateUIView(_ uiView: BannerView, context: Context) {
        if uiView.rootViewController == nil {
            uiView.rootViewController = AdaptiveBannerRootViewController.topViewController()
        }
    }

    static func dismantleUIView(_ uiView: BannerView, coordinator: Coordinator) {
        coordinator.detach()
        uiView.delegate = nil
        uiView.isHidden = true
    }

    final class Coordinator: NSObject, BannerViewDelegate {
        private weak var banner: BannerView?
        private let onAdLoaded: () -> Void
        private let onAdFailed: (Error) -> Void

        init(onAdLoaded: @escaping () -> Void, onAdFailed: @escaping (Error) -> Void) {
            self.onAdLoaded = onAdLoaded
            self.onAdFailed = onAdFailed
        }

        func attach(_ banner: BannerView) {
            self.banner = banner
        }

        func detach() {
            banner = nil
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
    /// Width passed to Google's anchored adaptive API (points). Uses `currentOrientationAnchoredAdaptiveBanner`.
    static func anchoredAdSize(forBannerSlotWidth slotWidth: CGFloat) -> AdSize {
        let w = max(320, slotWidth)
        return currentOrientationAnchoredAdaptiveBanner(width: w)
    }

    /// Vertical space to reserve for the banner (anchored adaptive height for the current orientation).
    static func reservedSlotHeight(forOuterLayoutWidth layoutWidth: CGFloat) -> CGFloat {
        anchoredAdSize(forBannerSlotWidth: max(320, layoutWidth - 24)).size.height
    }
}

/// Anchored adaptive AdMob banner in a FanGeo-style rounded glass shell. Reserves adaptive height before the ad loads to avoid layout jumps.
struct AdaptiveBannerView: View {
    @Environment(\.colorScheme) private var colorScheme

    let adUnitID: String
    /// Width available **inside** the parent’s horizontal padding (e.g. Discover row after `FGSpacing.lg`). Inner ad slot subtracts this view’s own horizontal padding (12+12).
    let layoutWidth: CGFloat
    var onAdLoaded: () -> Void = {}
    var onAdFailed: (Error) -> Void = { _ in }

    private var bannerSlotWidth: CGFloat {
        max(320, layoutWidth - 24)
    }

    private var adSize: AdSize {
        AdaptiveBannerLayout.anchoredAdSize(forBannerSlotWidth: bannerSlotWidth)
    }

    var body: some View {
        let size = adSize.size
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.black.opacity(colorScheme == .dark ? 0.28 : 0.08))
                AdaptiveBannerRepresentable(
                    adUnitID: adUnitID,
                    adSize: adSize,
                    onAdLoaded: onAdLoaded,
                    onAdFailed: onAdFailed
                )
                .frame(width: size.width, height: size.height)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(FGColor.divider(colorScheme).opacity(colorScheme == .dark ? 0.45 : 0.35), lineWidth: 1)
            }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.42 : 0.14), radius: 14, y: 7)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: size.height, maxHeight: size.height)
        .accessibilityElement(children: .contain)
    }
}
