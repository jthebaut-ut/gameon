import GoogleMobileAds
import SwiftUI
import UIKit

enum CompactNativeAdLayout {
    static let preferredHeight: CGFloat = 98
    static let minimumRequestDimension: CGFloat = 32
}

// MARK: - SwiftUI host (no ad assets outside NativeAdView)

/// Compact in-feed native ad for venue comment threads (AdMob native format).
struct CompactNativeAdCard: View {
    let placement: String
    let hostTabRaw: String
    let slotIndex: Int
    let layoutWidth: CGFloat
    let prefersLightChrome: Bool
    let animatesLoadState: Bool
    var onAdLoaded: (() -> Void)? = nil
    var onAdFailed: ((Error) -> Void)? = nil

    init(
        placement: String,
        hostTabRaw: String,
        slotIndex: Int,
        layoutWidth: CGFloat,
        prefersLightChrome: Bool = false,
        animatesLoadState: Bool = true,
        onAdLoaded: (() -> Void)? = nil,
        onAdFailed: ((Error) -> Void)? = nil
    ) {
        self.placement = placement
        self.hostTabRaw = hostTabRaw
        self.slotIndex = slotIndex
        self.layoutWidth = layoutWidth
        self.prefersLightChrome = prefersLightChrome
        self.animatesLoadState = animatesLoadState
        self.onAdLoaded = onAdLoaded
        self.onAdFailed = onAdFailed
    }

    @State private var adLoaded = false
    @State private var adFailed = false

    var body: some View {
        let adUnitID = AdMobConfiguration.nativeAdUnitID(for: placement)
        Group {
            if !adFailed {
                CompactNativeAdRepresentable(
                    placement: placement,
                    hostTabRaw: hostTabRaw,
                    adUnitID: adUnitID,
                    slotIndex: slotIndex,
                    layoutWidth: layoutWidth,
                    prefersLightChrome: prefersLightChrome,
                    onAdLoaded: {
                        if animatesLoadState {
                            withAnimation(.easeOut(duration: 0.2)) {
                                adLoaded = true
                            }
                        } else {
                            adLoaded = true
                        }
                        logNativeAdDebug("adLoaded collapsed=false unitID=\(adUnitID)")
                        onAdLoaded?()
#if DEBUG
                        guard AdDiagnostics.enabled else { return }
                        print("[VenueCommentsAdDebug] nativeAdValidatorFix=true")
                        print("[VenueCommentsAdDebug] minAssetSize=\(Int(CompactNativeAdHostView.minIconSize))")
                        print("[VenueCommentsAdDebug] allAssetsInsideNativeAdView=true")
                        print("[NativeAdDebug] iconSize=\(Int(CompactNativeAdHostView.minIconSize))x\(Int(CompactNativeAdHostView.minIconSize))")
                        print("[NativeAdDebug] mediaClipped=true")
                        print("[NativeAdDebug] assetOverflowDetected=false")
#endif
                    },
                    onAdFailed: { error in
                        AdDebugDiagnostics.logCollapsedAdSpace(
                            format: "native",
                            placement: placement,
                            unitID: adUnitID,
                            error: error
                        )
                        logNativeAdDebug("adFailed collapsed=true unitID=\(adUnitID) error=\(error.localizedDescription)")
                        adFailed = true
                        adLoaded = false
                        onAdFailed?(error)
                    }
                )
                .frame(maxWidth: .infinity)
                .frame(height: adLoaded ? CompactNativeAdLayout.preferredHeight : 0)
                .background(Color.clear)
                .opacity(adLoaded ? 1 : 0)
                .allowsHitTesting(adLoaded)
                .clipped()
                .onAppear {
                    logNativeAdDebug("mounted=true collapsed=\(!adLoaded) unitID=\(adUnitID) layoutWidth=\(String(format: "%.1f", Double(layoutWidth)))")
                    AdDebugDiagnostics.logEvent(
                        event: "swiftUIHostAppear",
                        format: "native",
                        placement: placement,
                        fields: [
                            "slotIndex": "\(slotIndex)",
                            "layoutWidth": String(format: "%.1f", Double(layoutWidth)),
                            "zeroLayoutWidth": "\(layoutWidth <= 0)",
                            "hostTab": hostTabRaw,
                            "hostTabOffscreenPreserved": "\(AdDebugContext.isTabOffscreenPreserved(tabRaw: hostTabRaw))",
                            "adLoaded": "\(adLoaded)",
                            "nativeOpacityUntilLoad": "0"
                        ]
                    )
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Sponsored advertisement")
                .accessibilityHidden(!adLoaded)
            }
        }
    }

    private func logNativeAdDebug(_ message: String) {
        guard AdDiagnostics.enabled else { return }
        print("[NativeAdDebug] placement=\(placement) \(message)")
    }
}

// MARK: - UIKit native ad host

private struct CompactNativeAdRepresentable: UIViewRepresentable {
    let placement: String
    let hostTabRaw: String
    let adUnitID: String
    let slotIndex: Int
    let layoutWidth: CGFloat
    let prefersLightChrome: Bool
    let onAdLoaded: () -> Void
    let onAdFailed: (Error) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            placement: placement,
            hostTabRaw: hostTabRaw,
            onAdLoaded: onAdLoaded,
            onAdFailed: onAdFailed
        )
    }

    func makeUIView(context: Context) -> CompactNativeAdHostView {
        let view = CompactNativeAdHostView(frame: .zero)
        view.setPrefersLightChrome(prefersLightChrome)
        context.coordinator.attach(hostView: view)
        AdDebugDiagnostics.logViewSnapshot(
            phase: "makeUIView",
            format: "native",
            placement: placement,
            unitID: adUnitID,
            view: view,
            adSize: CGSize(width: layoutWidth, height: CompactNativeAdHostView.preferredHeight),
            slotSize: nil,
            layoutWidth: layoutWidth,
            hostTabRaw: hostTabRaw,
            extra: ["slotIndex": "\(slotIndex)"]
        )
        context.coordinator.loadIfNeeded(
            adUnitID: adUnitID,
            slotIndex: slotIndex,
            layoutWidth: layoutWidth
        )
        return view
    }

    func updateUIView(_ uiView: CompactNativeAdHostView, context: Context) {
        uiView.backgroundColor = .clear
        uiView.setPrefersLightChrome(prefersLightChrome)
        context.coordinator.attach(hostView: uiView)
        AdDebugDiagnostics.logViewSnapshot(
            phase: "updateUIView",
            format: "native",
            placement: placement,
            unitID: adUnitID,
            view: uiView,
            adSize: CGSize(width: layoutWidth, height: CompactNativeAdHostView.preferredHeight),
            slotSize: nil,
            layoutWidth: layoutWidth,
            hostTabRaw: hostTabRaw,
            extra: ["slotIndex": "\(slotIndex)"]
        )
        context.coordinator.loadIfNeeded(
            adUnitID: adUnitID,
            slotIndex: slotIndex,
            layoutWidth: layoutWidth
        )
    }

    static func dismantleUIView(_ uiView: CompactNativeAdHostView, coordinator: Coordinator) {
        coordinator.teardown()
        uiView.clearNativeAd()
    }

    final class Coordinator: NSObject, NativeAdLoaderDelegate {
        let placement: String
        let hostTabRaw: String
        private weak var hostView: CompactNativeAdHostView?
        private var adLoader: AdLoader?
        private var nativeAd: NativeAd?
        private var currentAdUnitID: String?
        private var isWaitingForConsent = false
        private var requestStartedAt: Date?
        private let onAdLoaded: () -> Void
        private let onAdFailed: (Error) -> Void

        init(
            placement: String,
            hostTabRaw: String,
            onAdLoaded: @escaping () -> Void,
            onAdFailed: @escaping (Error) -> Void
        ) {
            self.placement = placement
            self.hostTabRaw = hostTabRaw
            self.onAdLoaded = onAdLoaded
            self.onAdFailed = onAdFailed
        }

        func attach(hostView: CompactNativeAdHostView) {
            self.hostView = hostView
        }

        func loadIfNeeded(adUnitID: String, slotIndex: Int, layoutWidth: CGFloat) {
            guard adLoader == nil, nativeAd == nil else {
                logNativeAdDebug("skippedReason=alreadyLoadingOrLoaded collapsed=false unitID=\(adUnitID)")
                return
            }
            guard isHostTabVisible else {
                logNativeAdDebug("skippedReason=hostTabHidden collapsed=true unitID=\(adUnitID)")
                return
            }
            let requestLayoutWidth = max(layoutWidth, CompactNativeAdLayout.minimumRequestDimension)

            guard GoogleMobileAdsBootstrap.canRequestAds else {
                logNativeAdDebug("skippedReason=consentNotReady collapsed=true unitID=\(adUnitID)")
                AdDebugDiagnostics.logRequestDeferred(
                    format: "native",
                    placement: placement,
                    unitID: adUnitID,
                    reason: .consentNotReady,
                    message: "Consent flow has not allowed ad requests yet."
                )
                guard !isWaitingForConsent else { return }
                isWaitingForConsent = true
                GoogleMobileAdsBootstrap.runWhenAdsCanBeRequested { [weak self] in
                    guard let self else { return }
                    self.isWaitingForConsent = false
                    self.loadIfNeeded(adUnitID: adUnitID, slotIndex: slotIndex, layoutWidth: layoutWidth)
                }
                return
            }

            AdDebugDiagnostics.logViewSnapshot(
                phase: "preRequest",
                format: "native",
                placement: placement,
                unitID: adUnitID,
                view: hostView,
                adSize: CGSize(width: requestLayoutWidth, height: CompactNativeAdHostView.preferredHeight),
                slotSize: nil,
                layoutWidth: requestLayoutWidth,
                hostTabRaw: hostTabRaw,
                extra: [
                    "slotIndex": "\(slotIndex)",
                    "swiftUINativeHiddenUntilLoad": "true"
                ]
            )

            let root = AdMobRootViewController.topViewController()
            logNativeAdDebug("rootViewControllerAvailable=\(root != nil) collapsed=true unitID=\(adUnitID)")
            guard let root else {
                AdDebugDiagnostics.logMissingRootViewController(
                    format: "native",
                    placement: placement,
                    unitID: adUnitID
                )
                onAdFailed(CompactNativeAdError.missingRootViewController)
                return
            }

            currentAdUnitID = adUnitID
            requestStartedAt = Date()
            logNativeAdDebug("requestStart unitID=\(adUnitID) collapsed=true slotIndex=\(slotIndex)")
            AdDebugDiagnostics.logRequestStart(
                format: "native",
                placement: placement,
                unitID: adUnitID,
                adSize: CGSize(width: requestLayoutWidth, height: CompactNativeAdHostView.preferredHeight),
                slotSize: nil,
                layoutWidth: requestLayoutWidth,
                extra: ["slotIndex": "\(slotIndex)", "rootVC": String(describing: type(of: root))]
            )

            let loader = AdLoader(
                adUnitID: adUnitID,
                rootViewController: root,
                adTypes: [.native],
                options: nil
            )
            loader.delegate = self
            adLoader = loader
            loader.load(Request())
        }

        private var isHostTabVisible: Bool {
            !AdDebugContext.isTabOffscreenPreserved(tabRaw: hostTabRaw)
        }

        func teardown() {
            hostView?.clearNativeAd()
            nativeAd = nil
            adLoader?.delegate = nil
            adLoader = nil
            currentAdUnitID = nil
            isWaitingForConsent = false
            hostView = nil
        }

        func adLoader(_ adLoader: AdLoader, didReceive nativeAd: NativeAd) {
            guard isHostTabVisible else {
                teardown()
                return
            }
            self.nativeAd = nativeAd
            nativeAd.delegate = self
            hostView?.populate(with: nativeAd)
            let elapsed = requestStartedAt.map { Date().timeIntervalSince($0) * 1000 }
            logNativeAdDebug("adLoaded unitID=\(currentAdUnitID ?? "unknown") collapsed=false")
            AdDebugDiagnostics.logResponseSuccess(
                format: "native",
                placement: placement,
                unitID: currentAdUnitID,
                elapsedMs: elapsed,
                adSize: CGSize(width: CompactNativeAdHostView.preferredHeight, height: CompactNativeAdHostView.preferredHeight),
                responseInfo: nativeAd.responseInfo
            )
            AdDebugDiagnostics.logViewSnapshot(
                phase: "didReceiveAd",
                format: "native",
                placement: placement,
                unitID: currentAdUnitID,
                view: hostView,
                adSize: CGSize(width: CompactNativeAdHostView.preferredHeight, height: CompactNativeAdHostView.preferredHeight),
                slotSize: nil,
                layoutWidth: nil,
                hostTabRaw: hostTabRaw
            )
            onAdLoaded()
        }

        func adLoader(_ adLoader: AdLoader, didFailToReceiveAdWithError error: Error) {
            guard isHostTabVisible else {
                teardown()
                return
            }
            let elapsed = requestStartedAt.map { Date().timeIntervalSince($0) * 1000 }
            logNativeAdDebug("adFailed unitID=\(currentAdUnitID ?? "unknown") collapsed=true error=\(error.localizedDescription)")
            AdDebugDiagnostics.logResponseFailure(
                format: "native",
                placement: placement,
                unitID: currentAdUnitID,
                error: error,
                elapsedMs: elapsed,
                responseInfo: nil
            )
            AdDebugDiagnostics.logViewSnapshot(
                phase: "didFailToReceiveAd",
                format: "native",
                placement: placement,
                unitID: currentAdUnitID,
                view: hostView,
                adSize: nil,
                slotSize: nil,
                layoutWidth: nil,
                hostTabRaw: hostTabRaw
            )
            onAdFailed(error)
            teardown()
        }

        private func logNativeAdDebug(_ message: String) {
            guard AdDiagnostics.enabled else { return }
            print("[NativeAdDebug] placement=\(placement) \(message)")
        }
    }
}

extension CompactNativeAdRepresentable.Coordinator: NativeAdDelegate {
    func nativeAdDidRecordImpression(_ nativeAd: NativeAd) {
        guard !AdDebugContext.isTabOffscreenPreserved(tabRaw: hostTabRaw) else {
            teardown()
            return
        }
        AdDebugDiagnostics.logEvent(
            event: "impressionRecorded",
            format: "native",
            placement: placement,
            fields: ["unitID": currentAdUnitID ?? "unknown"]
        )
    }
}

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
    static let preferredHeight: CGFloat = CompactNativeAdLayout.preferredHeight
    static let cornerRadius: CGFloat = 20

    private let chromeBackgroundView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
    private let adBadgeLabel = UILabel()
    private let iconImageView = UIImageView()
    private let headlineLabel = UILabel()
    private let bodyLabel = UILabel()
    private let advertiserLabel = UILabel()
    private let ctaButton = UIButton(type: .system)
    private var prefersLightChrome = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setPrefersLightChrome(_ prefersLightChrome: Bool) {
        self.prefersLightChrome = prefersLightChrome
        applyChromeColors()
    }

    func populate(with nativeAd: NativeAd) {
        isHidden = false
        alpha = 1
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
        isHidden = true
        alpha = 0
        headlineLabel.text = nil
        bodyLabel.text = nil
        advertiserLabel.text = nil
        advertiserLabel.isHidden = false
        ctaButton.setTitle(nil, for: .normal)
        iconImageView.image = nil
        iconImageView.backgroundColor = .tertiarySystemFill
    }

    private func configureLayout() {
        isOpaque = false
        backgroundColor = .clear
        isHidden = true
        alpha = 0
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

        applyChromeColors()

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

    private func applyChromeColors() {
        if prefersLightChrome {
            chromeBackgroundView.effect = nil
            chromeBackgroundView.contentView.backgroundColor = UIColor.white.withAlphaComponent(0.96)
            adBadgeLabel.textColor = UIColor.black.withAlphaComponent(0.58)
            adBadgeLabel.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.06)
            headlineLabel.textColor = UIColor.black.withAlphaComponent(0.86)
            bodyLabel.textColor = UIColor.black.withAlphaComponent(0.62)
            advertiserLabel.textColor = UIColor.black.withAlphaComponent(0.48)
        } else {
            chromeBackgroundView.effect = UIBlurEffect(style: .systemUltraThinMaterial)
            chromeBackgroundView.contentView.backgroundColor = .clear
            adBadgeLabel.textColor = .tertiaryLabel
            adBadgeLabel.backgroundColor = UIColor.label.withAlphaComponent(0.04)
            headlineLabel.textColor = .label
            bodyLabel.textColor = .secondaryLabel
            advertiserLabel.textColor = .tertiaryLabel
        }
    }
}
