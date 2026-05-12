import SwiftUI
import UIKit
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

private enum UIApplicationTopViewController {
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

// MARK: - SwiftUI wrapper

/// Anchored adaptive banner; loads on the next main run loop so Discover layout is not blocked.
struct AdMobBannerView: View {
    let adUnitID: String
    let bannerWidth: CGFloat
    var onAdLoaded: () -> Void
    var onAdFailed: (Error) -> Void

    var body: some View {
        let w = max(320, bannerWidth)
        let adSize = currentOrientationAnchoredAdaptiveBanner(width: w)
        AdMobBannerRepresentable(
            adUnitID: adUnitID,
            adSize: adSize,
            onAdLoaded: onAdLoaded,
            onAdFailed: onAdFailed
        )
        .frame(width: adSize.size.width, height: adSize.size.height)
    }
}

private struct AdMobBannerRepresentable: UIViewRepresentable {
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
                banner.rootViewController = UIApplicationTopViewController.topViewController()
            }
            banner.load(Request())
        }

        return banner
    }

    func updateUIView(_ uiView: BannerView, context: Context) {
        if uiView.rootViewController == nil {
            uiView.rootViewController = UIApplicationTopViewController.topViewController()
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
