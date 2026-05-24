import SwiftUI

struct BusinessProSubscriptionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private let proFeatures = [
        "Unlimited venue listings",
        "Unlimited hosted games",
        "Analytics access"
    ]

    private let freeFeatures = [
        "5 venue listings",
        "5 hosted games/month"
    ]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                header
                proPlanCard
                freePlanCard
                promoExplanation
                actionButtons
            }
            .padding(20)
        }
        .background(background)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(FGColor.accentGreen)
                    .frame(width: 46, height: 46)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text("FanGeo Business Pro")
                        .font(.system(size: 28, weight: .black, design: .rounded))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                    Text("Compare free business tools with unlimited listings and hosting.")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var proPlanCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            planHeader(
                title: "Business Pro",
                subtitle: "Summer Launch Promotion",
                badge: "PROMO",
                badgeColor: FGColor.accentYellow
            )

            Text("Unlimited venue listings and hosted games FREE until Aug 31, 2026")
                .font(.title3.weight(.bold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)

            Text("Then $19.99/month")
                .font(.caption.weight(.heavy))
                .foregroundStyle(FGColor.secondaryText(colorScheme))

            planFeatureList(proFeatures, tint: FGColor.accentGreen)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            FGColor.accentGreen.opacity(colorScheme == .dark ? 0.22 : 0.14),
                            FGColor.accentYellow.opacity(colorScheme == .dark ? 0.18 : 0.12)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .allowsHitTesting(false)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.16 : 0.42), lineWidth: 1)
        }
    }

    private var freePlanCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            planHeader(
                title: "FanGeo Business",
                subtitle: "Free business tools for sports venues",
                badge: "FREE",
                badgeColor: FGColor.accentBlue
            )

            Text("Free plan")
                .font(.caption.weight(.heavy))
                .foregroundStyle(FGColor.secondaryText(colorScheme))

            planFeatureList(freeFeatures, tint: FGColor.accentBlue)
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme).opacity(0.72), lineWidth: 1)
        }
    }

    private func planHeader(
        title: String,
        subtitle: String,
        badge: String,
        badgeColor: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline.weight(.black))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                Text(subtitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Text(badge)
                .font(.caption2.weight(.black))
                .foregroundStyle(badgeColor)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(badgeColor.opacity(colorScheme == .dark ? 0.20 : 0.12), in: Capsule(style: .continuous))
        }
    }

    private func planFeatureList(_ features: [String], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            ForEach(features, id: \.self) { feature in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(tint)
                    Text(feature)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var promoExplanation: some View {
        Text("All business accounts start free during the Summer Launch Promotion.")
            .font(.caption.weight(.semibold))
            .foregroundStyle(FGColor.secondaryText(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
    }

    private var actionButtons: some View {
        VStack(spacing: 10) {
            Button {
                dismiss()
            } label: {
                Text("Continue Free Summer Access")
                    .font(.headline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .foregroundStyle(.white)
                    .background(
                        LinearGradient(
                            colors: [FGColor.accentGreen, FGColor.businessGreen],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private var background: some View {
        ZStack {
            FGAdaptiveSurface.sheetRoot.ignoresSafeArea()
            LinearGradient(
                colors: [
                    FGColor.accentGreen.opacity(colorScheme == .dark ? 0.18 : 0.10),
                    FGColor.accentBlue.opacity(colorScheme == .dark ? 0.12 : 0.06),
                    Color.clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        }
    }
}

struct BusinessProSubscriptionView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            BusinessProSubscriptionView()
                .preferredColorScheme(.light)
            BusinessProSubscriptionView()
                .preferredColorScheme(.dark)
        }
    }
}
