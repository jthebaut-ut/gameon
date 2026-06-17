import SwiftUI

/// Compact native ad row for Going → Pro game lists. Wraps `CompactNativeAdCard` with FanGeo card chrome.
struct GoingNativeAdCard: View {
    let slot: GoingNativeAdSlot
    let shouldRequestAd: Bool

    @Environment(\.colorScheme) private var colorScheme
    @State private var layoutWidth: CGFloat = 320

    var body: some View {
        Group {
            if shouldRequestAd {
                GoingNativeAdCardContent(
                    slot: slot,
                    layoutWidth: max(CompactNativeAdLayout.minimumRequestDimension, layoutWidth),
                    colorScheme: colorScheme
                )
            }
        }
        .frame(maxWidth: .infinity)
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear {
                        updateLayoutWidth(geometry.size.width)
                    }
                    .onChange(of: geometry.size.width) { _, newWidth in
                        updateLayoutWidth(newWidth)
                    }
            }
        }
        .accessibilityHidden(!shouldRequestAd)
    }

    private func updateLayoutWidth(_ width: CGFloat) {
        guard width > 0, abs(layoutWidth - width) > 0.5 else { return }
        layoutWidth = width
    }
}

private struct GoingNativeAdCardContent: View {
    let slot: GoingNativeAdSlot
    let layoutWidth: CGFloat
    let colorScheme: ColorScheme

    @State private var adLoaded = false
    @State private var adFailed = false

    private var cardCornerRadius: CGFloat { 20 }
    private var borderOpacity: Double { colorScheme == .dark ? 0.30 : 0.18 }

    var body: some View {
        Group {
            if !adFailed {
                CompactNativeAdCard(
                    placement: "going.proGamesFeed",
                    hostTabRaw: "following",
                    slotIndex: slot.slotIndex,
                    layoutWidth: layoutWidth,
                    prefersLightChrome: colorScheme == .light,
                    animatesLoadState: false,
                    onAdLoaded: {
                        adLoaded = true
                        logGoingNativeAdDebug("adLoaded collapsed=false section=\(slot.section.rawValue)")
                    },
                    onAdFailed: { error in
                        adFailed = true
                        adLoaded = false
                        logGoingNativeAdDebug(
                            "adFailed collapsed=true section=\(slot.section.rawValue) error=\(error.localizedDescription)"
                        )
                    }
                )
                .frame(maxWidth: .infinity)
                .frame(height: adLoaded ? CompactNativeAdLayout.preferredHeight : 0)
                .opacity(adLoaded ? 1 : 0)
                .allowsHitTesting(adLoaded)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: displayHeight)
        .background {
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .fill(Color.clear)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .strokeBorder(FGColor.mutedText(colorScheme).opacity(borderOpacity), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
        .onAppear {
            logGoingNativeAdDebug(
                "mounted=true collapsed=\(!adLoaded) slotIndex=\(slot.slotIndex) afterCard=\(slot.insertedAfterCardPosition)"
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sponsored advertisement")
        .accessibilityHidden(!adLoaded)
    }

    private var displayHeight: CGFloat {
        if adFailed { return 0 }
        return adLoaded ? CompactNativeAdLayout.preferredHeight : 0
    }

    private func logGoingNativeAdDebug(_ message: String) {
        guard AdDiagnostics.enabled else { return }
        print("[GoingProAdDebug] placement=going.proGamesFeed \(message)")
    }
}
