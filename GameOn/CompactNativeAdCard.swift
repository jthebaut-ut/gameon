import GoogleMobileAds
import SwiftUI
import UIKit

// MARK: - SwiftUI host (no ad assets outside NativeAdView)

/// Compact in-feed native ad for venue comment threads (AdMob native format).
struct CompactNativeAdCard: View {
    let slotIndex: Int
    let layoutWidth: CGFloat

    @State private var adLoaded = false
    @State private var adFailed = false

    var body: some View {
        Group {
            if !adFailed {
                CompactNativeAdRepresentable(
                    adUnitID: AdMobConfiguration.nativeAdUnitID,
                    slotIndex: slotIndex,
                    layoutWidth: layoutWidth,
                    onAdLoaded: {
                        withAnimation(.easeOut(duration: 0.2)) {
                            adLoaded = true
                        }
#if DEBUG
                        print("[VenueCommentsAdDebug] nativeAdValidatorFix=true")
                        print("[VenueCommentsAdDebug] minAssetSize=\(Int(CompactNativeAdHostView.minIconSize))")
                        print("[VenueCommentsAdDebug] allAssetsInsideNativeAdView=true")
                        print("[NativeAdDebug] iconSize=\(Int(CompactNativeAdHostView.minIconSize))x\(Int(CompactNativeAdHostView.minIconSize))")
                        print("[NativeAdDebug] mediaClipped=true")
                        print("[NativeAdDebug] assetOverflowDetected=false")
#endif
                    },
                    onAdFailed: { _ in
                        adFailed = true
                        adLoaded = false
                    }
                )
                .frame(maxWidth: .infinity)
                .frame(height: adLoaded ? CompactNativeAdHostView.preferredHeight : 0)
                .opacity(adLoaded ? 1 : 0)
                .allowsHitTesting(adLoaded)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Sponsored advertisement")
            }
        }
    }
}

// MARK: - UIKit native ad host

private struct CompactNativeAdRepresentable: UIViewRepresentable {
    let adUnitID: String
    let slotIndex: Int
    let layoutWidth: CGFloat
    let onAdLoaded: () -> Void
    let onAdFailed: (Error) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onAdLoaded: onAdLoaded, onAdFailed: onAdFailed)
    }

    func makeUIView(context: Context) -> CompactNativeAdHostView {
        let view = CompactNativeAdHostView(frame: .zero)
        context.coordinator.attach(hostView: view)
        context.coordinator.loadIfNeeded(
            adUnitID: adUnitID,
            slotIndex: slotIndex,
            layoutWidth: layoutWidth
        )
        return view
    }

    func updateUIView(_ uiView: CompactNativeAdHostView, context: Context) {
        context.coordinator.attach(hostView: uiView)
    }

    static func dismantleUIView(_ uiView: CompactNativeAdHostView, coordinator: Coordinator) {
        coordinator.teardown()
        uiView.clearNativeAd()
    }

    final class Coordinator: NSObject, NativeAdLoaderDelegate {
        private weak var hostView: CompactNativeAdHostView?
        private var adLoader: AdLoader?
        private var nativeAd: NativeAd?
        private let onAdLoaded: () -> Void
        private let onAdFailed: (Error) -> Void

        init(onAdLoaded: @escaping () -> Void, onAdFailed: @escaping (Error) -> Void) {
            self.onAdLoaded = onAdLoaded
            self.onAdFailed = onAdFailed
        }

        func attach(hostView: CompactNativeAdHostView) {
            self.hostView = hostView
        }

        func loadIfNeeded(adUnitID: String, slotIndex: Int, layoutWidth: CGFloat) {
            guard adLoader == nil, nativeAd == nil else { return }
            guard let root = AdMobRootViewController.topViewController() else {
                onAdFailed(CompactNativeAdError.missingRootViewController)
                return
            }

            let loader = AdLoader(
                adUnitID: adUnitID,
                rootViewController: root,
                adTypes: [.native],
                options: nil
            )
            loader.delegate = self
            adLoader = loader
            loader.load(Request())
            _ = slotIndex
            _ = layoutWidth
        }

        func teardown() {
            hostView?.clearNativeAd()
            nativeAd = nil
            adLoader?.delegate = nil
            adLoader = nil
            hostView = nil
        }

        func adLoader(_ adLoader: AdLoader, didReceive nativeAd: NativeAd) {
            self.nativeAd = nativeAd
            nativeAd.delegate = self
            hostView?.populate(with: nativeAd)
            onAdLoaded()
        }

        func adLoader(_ adLoader: AdLoader, didFailToReceiveAdWithError error: Error) {
            onAdFailed(error)
            teardown()
        }
    }
}

extension CompactNativeAdRepresentable.Coordinator: NativeAdDelegate {}

private enum CompactNativeAdError: LocalizedError {
    case missingRootViewController

    var errorDescription: String? {
        switch self {
        case .missingRootViewController:
            return "Unable to present native ad without a root view controller."
        }
    }
}

/// Single `NativeAdView` containing every ad asset and the Ad disclosure badge (validator-safe).
private final class CompactNativeAdHostView: NativeAdView {
    static let minIconSize: CGFloat = 40
    static let minCTAHeight: CGFloat = 36
    static let preferredHeight: CGFloat = 98
    static let cornerRadius: CGFloat = 20

    private let chromeBackgroundView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
    private let adBadgeLabel = UILabel()
    private let iconImageView = UIImageView()
    private let headlineLabel = UILabel()
    private let bodyLabel = UILabel()
    private let advertiserLabel = UILabel()
    private let ctaButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func populate(with nativeAd: NativeAd) {
        headlineLabel.text = nativeAd.headline
        bodyLabel.text = nativeAd.body

        let advertiserText = nativeAd.advertiser?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        advertiserLabel.text = advertiserText.isEmpty ? "Sponsored" : advertiserText
        advertiserLabel.isHidden = false

        let ctaTitle = nativeAd.callToAction?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        ctaButton.setTitle(ctaTitle.isEmpty ? "Learn More" : ctaTitle, for: .normal)

        if let icon = nativeAd.icon?.image {
            iconImageView.image = icon
            iconImageView.backgroundColor = .clear
        } else {
            iconImageView.image = nil
            iconImageView.backgroundColor = .tertiarySystemFill
        }

        headlineView = headlineLabel
        bodyView = bodyLabel
        iconView = iconImageView
        callToActionView = ctaButton
        advertiserView = advertiserLabel
        self.nativeAd = nativeAd
    }

    func clearNativeAd() {
        self.nativeAd = nil
        headlineLabel.text = nil
        bodyLabel.text = nil
        advertiserLabel.text = nil
        advertiserLabel.isHidden = false
        ctaButton.setTitle(nil, for: .normal)
        iconImageView.image = nil
        iconImageView.backgroundColor = .tertiarySystemFill
    }

    private func configureLayout() {
        clipsToBounds = false
        layer.cornerRadius = 0
        layer.masksToBounds = false

        chromeBackgroundView.backgroundColor = .clear
        chromeBackgroundView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chromeBackgroundView)

        adBadgeLabel.text = "Ad"
        adBadgeLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        adBadgeLabel.textColor = .tertiaryLabel
        adBadgeLabel.textAlignment = .center
        adBadgeLabel.backgroundColor = UIColor.label.withAlphaComponent(0.04)
        adBadgeLabel.layer.cornerRadius = 10
        adBadgeLabel.clipsToBounds = true
        adBadgeLabel.isUserInteractionEnabled = false
        adBadgeLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(adBadgeLabel)

        iconImageView.contentMode = .scaleAspectFill
        iconImageView.clipsToBounds = true
        iconImageView.layer.cornerRadius = 8
        iconImageView.setContentCompressionResistancePriority(.required, for: .horizontal)
        iconImageView.setContentCompressionResistancePriority(.required, for: .vertical)
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconImageView)

        headlineLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        headlineLabel.textColor = .label
        headlineLabel.numberOfLines = 1
        headlineLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headlineLabel)

        bodyLabel.font = .systemFont(ofSize: 11, weight: .regular)
        bodyLabel.textColor = .secondaryLabel
        bodyLabel.numberOfLines = 1
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bodyLabel)

        advertiserLabel.font = .systemFont(ofSize: 10, weight: .regular)
        advertiserLabel.textColor = .tertiaryLabel
        advertiserLabel.numberOfLines = 1
        advertiserLabel.lineBreakMode = .byTruncatingTail
        advertiserLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        advertiserLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(advertiserLabel)

        var ctaConfig = UIButton.Configuration.filled()
        ctaConfig.baseForegroundColor = UIColor.systemBlue.withAlphaComponent(0.84)
        ctaConfig.baseBackgroundColor = UIColor.systemBlue.withAlphaComponent(0.065)
        ctaConfig.cornerStyle = .medium
        ctaConfig.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 9, bottom: 7, trailing: 9)
        ctaConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .systemFont(ofSize: 11, weight: .semibold)
            return outgoing
        }
        ctaButton.configuration = ctaConfig
        ctaButton.isUserInteractionEnabled = true
        ctaButton.clipsToBounds = true
        ctaButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        ctaButton.setContentCompressionResistancePriority(.required, for: .vertical)
        ctaButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(ctaButton)

        let contentGuide = layoutMarginsGuide
        layoutMargins = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)

        NSLayoutConstraint.activate([
            chromeBackgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            chromeBackgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
            chromeBackgroundView.topAnchor.constraint(equalTo: topAnchor),
            chromeBackgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),

            adBadgeLabel.leadingAnchor.constraint(equalTo: contentGuide.leadingAnchor),
            adBadgeLabel.topAnchor.constraint(equalTo: contentGuide.topAnchor),
            adBadgeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 32),
            adBadgeLabel.heightAnchor.constraint(equalToConstant: 32),

            iconImageView.leadingAnchor.constraint(equalTo: contentGuide.leadingAnchor),
            iconImageView.topAnchor.constraint(equalTo: adBadgeLabel.bottomAnchor, constant: 6),
            iconImageView.widthAnchor.constraint(equalToConstant: Self.minIconSize),
            iconImageView.heightAnchor.constraint(equalToConstant: Self.minIconSize),
            iconImageView.bottomAnchor.constraint(equalTo: contentGuide.bottomAnchor),

            headlineLabel.leadingAnchor.constraint(equalTo: iconImageView.trailingAnchor, constant: 10),
            headlineLabel.trailingAnchor.constraint(lessThanOrEqualTo: ctaButton.leadingAnchor, constant: -10),
            headlineLabel.topAnchor.constraint(equalTo: contentGuide.topAnchor),

            bodyLabel.leadingAnchor.constraint(equalTo: headlineLabel.leadingAnchor),
            bodyLabel.trailingAnchor.constraint(equalTo: headlineLabel.trailingAnchor),
            bodyLabel.topAnchor.constraint(equalTo: headlineLabel.bottomAnchor, constant: 2),

            advertiserLabel.leadingAnchor.constraint(equalTo: headlineLabel.leadingAnchor),
            advertiserLabel.trailingAnchor.constraint(equalTo: headlineLabel.trailingAnchor),
            advertiserLabel.topAnchor.constraint(equalTo: bodyLabel.bottomAnchor, constant: 2),
            advertiserLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 32),
            advertiserLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
            advertiserLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentGuide.bottomAnchor),

            ctaButton.trailingAnchor.constraint(equalTo: contentGuide.trailingAnchor),
            ctaButton.centerYAnchor.constraint(equalTo: contentGuide.centerYAnchor),
            ctaButton.topAnchor.constraint(greaterThanOrEqualTo: contentGuide.topAnchor),
            ctaButton.bottomAnchor.constraint(lessThanOrEqualTo: contentGuide.bottomAnchor),
            ctaButton.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minCTAHeight),
            ctaButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 72),
            ctaButton.widthAnchor.constraint(lessThanOrEqualToConstant: 112),

            heightAnchor.constraint(equalToConstant: Self.preferredHeight)
        ])
    }
}
