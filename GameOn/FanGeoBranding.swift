import SwiftUI

enum FanGeoLogoVariant {
    case dark
    case white

    var assetName: String {
        switch self {
        case .dark: return "FanGeoLogo"
        case .white: return "FanGeoLogoWhite"
        }
    }
}

struct FanGeoInlineLogoView: View {
    let variant: FanGeoLogoVariant
    let width: CGFloat
    var innerPadding: CGFloat = 8
    var materialBackground = true

    var body: some View {
        let logo = Image(variant.assetName)
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .aspectRatio(contentMode: .fit)
            .frame(width: width)

        Group {
            if materialBackground {
                logo
                    .padding(innerPadding)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.10), radius: 14, y: 8)
            } else {
                logo
            }
        }
        .accessibilityHidden(true)
    }
}

struct FanGeoBrandHeroView: View {
    let title: String?
    let subtitle: String?
    let variant: FanGeoLogoVariant
    var logoWidth: CGFloat = 144
    var alignment: HorizontalAlignment = .leading
    var textAlignment: TextAlignment = .leading

    var body: some View {
        VStack(alignment: alignment, spacing: 14) {
            FanGeoInlineLogoView(variant: variant, width: logoWidth)

            if let title, !title.isEmpty {
                Text(title)
                    .font(.largeTitle.weight(.bold))
                    .multilineTextAlignment(textAlignment)
            }

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(textAlignment)
            }
        }
    }
}

struct FanGeoLoadingView: View {
    let message: String
    var tint: Color = .secondary
    var textColor: Color = .secondary

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(tint)
                .scaleEffect(0.95)

            Text(message)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(textColor)
                .multilineTextAlignment(.center)
        }
    }
}

struct FanGeoLogoWatermark: View {
    let variant: FanGeoLogoVariant
    let width: CGFloat
    var opacity: Double = 0.18

    var body: some View {
        Image(variant.assetName)
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .aspectRatio(contentMode: .fit)
            .frame(width: width)
            .opacity(opacity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
