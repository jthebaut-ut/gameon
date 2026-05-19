import SwiftUI
import UIKit

enum FanGeoAppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let appStorageKey = "fangeo.appearance.preference"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System Default"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var userInterfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: return .unspecified
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum FGColor {
    static func background(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.05, green: 0.07, blue: 0.10)
            : Color(red: 0.96, green: 0.975, blue: 0.995)
    }

    static func cardBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.77, green: 0.86, blue: 0.98, opacity: 0.10)
            : Color(red: 0.975, green: 0.985, blue: 1.0, opacity: 0.90)
    }

    static func primaryText(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white : Color(red: 0.08, green: 0.09, blue: 0.12)
    }

    static func secondaryText(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.78)
            : Color(red: 0.27, green: 0.31, blue: 0.38)
    }

    static func mutedText(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.56)
            : Color(red: 0.46, green: 0.50, blue: 0.57)
    }

    static func divider(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.76, green: 0.84, blue: 0.98, opacity: 0.14)
            : Color(red: 0.52, green: 0.62, blue: 0.78, opacity: 0.12)
    }

    static let accentYellow = Color(red: 0.98, green: 0.80, blue: 0.20)
    static let accentBlue = Color(red: 0.33, green: 0.63, blue: 0.94)
    static let accentGreen = Color(red: 0.22, green: 0.76, blue: 0.45)
    static let dangerRed = Color(red: 0.91, green: 0.25, blue: 0.28)
    static let businessGreen = Color(red: 0.18, green: 0.66, blue: 0.37)

    static let gradientStart = Color(red: 0.78, green: 0.90, blue: 0.99)
    static let gradientMiddle = Color(red: 0.43, green: 0.68, blue: 0.93)
    static let gradientEnd = Color(red: 0.24, green: 0.42, blue: 0.70)

    static var brandGradient: LinearGradient {
        LinearGradient(
            colors: [gradientStart, gradientMiddle, gradientEnd],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    static func screenGradient(_ scheme: ColorScheme) -> LinearGradient {
        let colors: [Color] = scheme == .dark
            ? [Color(red: 0.03, green: 0.05, blue: 0.08), Color(red: 0.07, green: 0.10, blue: 0.16)]
            : [Color.white, Color(red: 0.94, green: 0.97, blue: 1.0)]
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// Opaque / semantic UIKit-backed colors for sheet content so layered glass on device does not stack with near-white translucency.
enum FGAdaptiveSurface {
    static var sheetRoot: Color { Color(.systemGroupedBackground) }
    static var cardElevated: Color { Color(.secondarySystemGroupedBackground) }
    static var controlFill: Color { Color(.tertiarySystemGroupedBackground) }
    static var capsuleUnselected: Color { Color(.tertiarySystemFill) }
}

enum FGTypography {
    static let heroTitle = Font.system(size: 34, weight: .bold, design: .rounded)
    static let screenTitle = Font.system(size: 28, weight: .bold, design: .rounded)
    static let sectionTitle = Font.system(size: 20, weight: .semibold, design: .rounded)
    static let cardTitle = Font.system(size: 17, weight: .semibold, design: .rounded)
    static let body = Font.system(size: 16, weight: .regular, design: .default)
    static let caption = Font.system(size: 13, weight: .regular, design: .default)
    static let metadata = Font.system(size: 12, weight: .medium, design: .rounded)
}

enum FGSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 28
    static let hero: CGFloat = 40
}

enum FGRadius {
    static let small: CGFloat = 10
    static let medium: CGFloat = 14
    static let large: CGFloat = 18
    static let card: CGFloat = 22
    static let pill: CGFloat = 999
    static let sheet: CGFloat = 28
}

private struct FGSoftCardShadowModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .shadow(color: .black.opacity(0.08), radius: 14, y: 8)
    }
}

private struct FGFloatingShadowModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .shadow(color: .black.opacity(0.14), radius: 22, y: 12)
    }
}

private struct FGGlowShadowModifier: ViewModifier {
    let color: Color

    func body(content: Content) -> some View {
        content
            .shadow(color: color.opacity(0.20), radius: 18, y: 0)
    }
}

enum FGInteractionHaptics {
    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    static func softImpact() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.55)
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

struct FGPremiumPressButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.975
    var hapticOnPress = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .animation(.spring(response: 0.18, dampingFraction: 0.76), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                guard pressed, hapticOnPress else { return }
                FGInteractionHaptics.softImpact()
            }
    }
}

private struct FGSoftActiveGlowModifier: ViewModifier {
    let isActive: Bool
    let color: Color

    func body(content: Content) -> some View {
        content
            .shadow(color: color.opacity(isActive ? 0.16 : 0), radius: isActive ? 10 : 0, y: 0)
    }
}

private struct FGScreenBackgroundModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(FGColor.screenGradient(colorScheme).ignoresSafeArea())
    }
}

private struct FGCardStyleModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .padding(FGSpacing.lg)
            .background(FGColor.cardBackground(colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: FGRadius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: FGRadius.card, style: .continuous)
                    .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
            }
            .softCardShadow()
    }
}

private struct FGFloatingStyleModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .padding(FGSpacing.md)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: FGRadius.sheet, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: FGRadius.sheet, style: .continuous)
                    .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
            }
            .floatingShadow()
    }
}

private struct FGGlassCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(FGSpacing.lg)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(Color.black.opacity(colorScheme == .dark ? 0.28 : 0))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(Color.white.opacity(colorScheme == .dark ? 0.16 : 0.39))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(colorScheme == .dark ? 0.09 : 0.19),
                                        Color.white.opacity(0.02)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        colorScheme == .dark
                            ? Color.white.opacity(0.19)
                            : FGColor.divider(colorScheme),
                        lineWidth: colorScheme == .dark ? 1 : 0.75
                    )
            }
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.072),
                radius: 5,
                y: 2
            )
    }
}

private struct FGTitleStyleModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    var color: Color?

    func body(content: Content) -> some View {
        content
            .font(FGTypography.screenTitle)
            .foregroundStyle(color ?? FGColor.primaryText(colorScheme))
    }
}

private struct FGInputFieldStyleModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, FGSpacing.md)
            .padding(.vertical, FGSpacing.sm + 3)
            .background(
                FGColor.background(colorScheme).opacity(colorScheme == .dark ? 0.78 : 0.97)
            )
            .clipShape(RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                    .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
            }
    }
}

private struct FGProgressiveAppearModifier: ViewModifier {
    let isVisible: Bool
    let yOffset: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .offset(y: isVisible ? 0 : yOffset)
            .animation(.easeOut(duration: 0.24), value: isVisible)
    }
}

extension View {
    func softCardShadow() -> some View {
        modifier(FGSoftCardShadowModifier())
    }

    func floatingShadow() -> some View {
        modifier(FGFloatingShadowModifier())
    }

    func glowShadow(_ color: Color = FGColor.accentBlue) -> some View {
        modifier(FGGlowShadowModifier(color: color))
    }

    func softActiveGlow(_ isActive: Bool, color: Color = FGColor.accentBlue) -> some View {
        modifier(FGSoftActiveGlowModifier(isActive: isActive, color: color))
    }

    func fanGeoScreenBackground() -> some View {
        modifier(FGScreenBackgroundModifier())
    }

    func fanGeoCardStyle() -> some View {
        modifier(FGCardStyleModifier())
    }

    func fanGeoFloatingStyle() -> some View {
        modifier(FGFloatingStyleModifier())
    }

    func fanGeoGlassCard(cornerRadius: CGFloat = FGRadius.card) -> some View {
        modifier(FGGlassCardModifier(cornerRadius: cornerRadius))
    }

    func fanGeoTitleStyle(color: Color? = nil) -> some View {
        modifier(FGTitleStyleModifier(color: color))
    }

    func fanGeoInputFieldStyle() -> some View {
        modifier(FGInputFieldStyleModifier())
    }

    func progressiveAppear(isVisible: Bool, yOffset: CGFloat = 8) -> some View {
        modifier(FGProgressiveAppearModifier(isVisible: isVisible, yOffset: yOffset))
    }
}

struct FGCard<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FGSpacing.md) {
            content
        }
        .fanGeoCardStyle()
    }
}

struct FGPrimaryButton: View {
    let title: String
    var systemImage: String?
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: FGSpacing.sm) {
                if let systemImage, !systemImage.isEmpty {
                    Image(systemName: systemImage)
                }
                Text(title)
                    .font(FGTypography.cardTitle)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, FGSpacing.md)
            .background(
                isDisabled
                    ? AnyShapeStyle(Color.gray.opacity(0.35))
                    : AnyShapeStyle(FGColor.brandGradient)
            )
            .clipShape(RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous))
            .floatingShadow()
        }
        .buttonStyle(FGPremiumPressButtonStyle(hapticOnPress: true))
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.7 : 1)
    }
}

struct FGSecondaryButton: View {
    let title: String
    var systemImage: String?
    var isDisabled = false
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: FGSpacing.sm) {
                if let systemImage, !systemImage.isEmpty {
                    Image(systemName: systemImage)
                }
                Text(title)
                    .font(FGTypography.cardTitle)
            }
            .foregroundStyle(FGColor.primaryText(colorScheme))
            .frame(maxWidth: .infinity)
            .padding(.vertical, FGSpacing.md)
            .background(FGColor.cardBackground(colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                    .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
            }
        }
        .buttonStyle(FGPremiumPressButtonStyle(hapticOnPress: true))
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.6 : 1)
    }
}

struct FGSectionHeader<Trailing: View>: View {
    let title: String
    let subtitle: String?
    private let trailing: Trailing
    @Environment(\.colorScheme) private var colorScheme

    init(
        _ title: String,
        subtitle: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .top, spacing: FGSpacing.md) {
            VStack(alignment: .leading, spacing: FGSpacing.xs) {
                Text(title)
                    .font(FGTypography.sectionTitle)
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }
            }

            Spacer(minLength: FGSpacing.sm)
            trailing
        }
    }
}

extension FGSectionHeader where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil) {
        self.init(title, subtitle: subtitle) { EmptyView() }
    }
}

struct FGSearchBar: View {
    let placeholder: String
    @Binding var text: String
    var systemImage = "magnifyingglass"
    var onClear: (() -> Void)?
    var onSubmit: (() -> Void)?
    var submitLabel: SubmitLabel = .done
    var textInputAutocapitalization: TextInputAutocapitalization = .never
    var isFocused: FocusState<Bool>.Binding?
    var horizontalPadding: CGFloat = FGSpacing.md
    var verticalPadding: CGFloat = FGSpacing.sm + 2
    var cornerRadius: CGFloat = FGRadius.large
    var contentSpacing: CGFloat = FGSpacing.sm
    var textFont: Font = FGTypography.body
    var showsBackground = true
    /// Reserved trailing space inside the bar (e.g. Discover integrated location control).
    var trailingAccessoryInset: CGFloat = 0
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: contentSpacing) {
            Image(systemName: systemImage)
                .foregroundStyle(FGColor.mutedText(colorScheme))

            inputField

            if !text.isEmpty {
                Button {
                    text = ""
                    onClear?()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                }
                .buttonStyle(.plain)
            }

            if trailingAccessoryInset > 0 {
                Color.clear
                    .frame(width: trailingAccessoryInset)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .background {
            if showsBackground {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(FGColor.cardBackground(colorScheme))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            if showsBackground {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
            }
        }
    }

    @ViewBuilder
    private var inputField: some View {
        if let isFocused {
            TextField(placeholder, text: $text)
                .focused(isFocused)
                .textInputAutocapitalization(textInputAutocapitalization)
                .disableAutocorrection(true)
                .submitLabel(submitLabel)
                .onSubmit { onSubmit?() }
                .font(textFont)
        } else {
            TextField(placeholder, text: $text)
                .textInputAutocapitalization(textInputAutocapitalization)
                .disableAutocorrection(true)
                .submitLabel(submitLabel)
                .onSubmit { onSubmit?() }
                .font(textFont)
        }
    }
}

struct FGStatusPill: View {
    enum Kind {
        case approved
        case pending
        case rejected
        case business
        case custom(tint: Color)

        var tint: Color {
            switch self {
            case .approved: return FGColor.accentGreen
            case .pending: return FGColor.accentYellow
            case .rejected: return FGColor.dangerRed
            case .business: return FGColor.businessGreen
            case .custom(let tint): return tint
            }
        }
    }

    let title: String
    let kind: Kind

    var body: some View {
        Text(title)
            .font(FGTypography.metadata)
            .foregroundStyle(kind.tint)
            .padding(.horizontal, FGSpacing.sm + 2)
            .padding(.vertical, FGSpacing.xs + 2)
            .background(kind.tint.opacity(0.12))
            .clipShape(Capsule(style: .continuous))
    }
}

struct FGWrappingLayout: Layout {
    var horizontalSpacing: CGFloat = FGSpacing.xs
    var verticalSpacing: CGFloat = FGSpacing.xs

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let layout = measuredLayout(sizes: sizes, maxWidth: proposal.width)
        return CGSize(width: proposal.width ?? layout.width, height: layout.height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let layout = measuredLayout(sizes: sizes, maxWidth: bounds.width)

        for index in subviews.indices {
            subviews[index].place(
                at: CGPoint(
                    x: bounds.minX + layout.origins[index].x,
                    y: bounds.minY + layout.origins[index].y
                ),
                anchor: .topLeading,
                proposal: ProposedViewSize(sizes[index])
            )
        }
    }

    private func measuredLayout(sizes: [CGSize], maxWidth proposedMaxWidth: CGFloat?) -> (origins: [CGPoint], width: CGFloat, height: CGFloat) {
        let maxWidth = max(proposedMaxWidth ?? .greatestFiniteMagnitude, 1)
        var origins: [CGPoint] = []
        origins.reserveCapacity(sizes.count)

        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var measuredWidth: CGFloat = 0

        for size in sizes {
            let nextX = x == 0 ? size.width : x + horizontalSpacing + size.width
            if nextX > maxWidth, x > 0 {
                y += rowHeight + verticalSpacing
                x = 0
                rowHeight = 0
            }

            origins.append(CGPoint(x: x, y: y))
            measuredWidth = max(measuredWidth, x + size.width)
            rowHeight = max(rowHeight, size.height)
            x += (x == 0 ? 0 : horizontalSpacing) + size.width
        }

        return (origins, measuredWidth, y + rowHeight)
    }
}

struct FGEmptyState: View {
    let title: String
    let subtitle: String
    var systemImage: String?
    var showsLogo = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: FGSpacing.lg) {
            if showsLogo {
                FGInlineLogo(variant: .dark, width: 120)
            } else if let systemImage, !systemImage.isEmpty {
                Image(systemName: systemImage)
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
            }

            VStack(spacing: FGSpacing.sm) {
                Text(title)
                    .font(FGTypography.sectionTitle)
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .multilineTextAlignment(.center)
                Text(subtitle)
                    .font(FGTypography.body)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(FGSpacing.xxl)
    }
}

struct FGSmoothPlaceholderBlock: View {
    var height: CGFloat
    var cornerRadius: CGFloat = FGRadius.medium
    var opacity: Double = 0.10
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(FGColor.primaryText(colorScheme).opacity(opacity))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(FGColor.divider(colorScheme).opacity(0.65), lineWidth: 0.75)
            }
            .frame(height: height)
            .accessibilityHidden(true)
    }
}

struct FGInlineLogo: View {
    let variant: FanGeoLogoVariant
    let width: CGFloat

    var body: some View {
        Image(variant == .white ? "FanGeoLogoWhite" : "FanGeoLogo")
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .aspectRatio(contentMode: .fit)
            .frame(width: width)
            .accessibilityHidden(true)
    }
}

enum PokesUnseenEmphasis {
    static let ambientPeriod: TimeInterval = 3.0

    private static let warmAccent = Color(red: 1, green: 0.52, blue: 0.20)
    private static let warmAccentDeep = Color(red: 0.95, green: 0.30, blue: 0.12)

    /// Slow ambient pulse (~3s); 0…1 via sine.
    static func pulse(at date: Date, period: TimeInterval = ambientPeriod) -> CGFloat {
        let t = date.timeIntervalSinceReferenceDate
        return CGFloat(0.5 + 0.5 * sin(t * 2 * .pi / period))
    }

    /// 0…1 light-sweep position across the card (~3s loop).
    static func sweep(at date: Date, period: TimeInterval = ambientPeriod) -> CGFloat {
        let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
        return CGFloat(t)
    }

    static func warmAccentColor(opacity: Double) -> Color {
        warmAccent.opacity(opacity)
    }

    static func warmAccentDeepColor(opacity: Double) -> Color {
        warmAccentDeep.opacity(opacity)
    }
}

/// Breathing warm glow, light sweep, and border for the profile Pokes highlights card.
struct PokesUnseenHighlightsEmphasisModifier: ViewModifier {
    let isActive: Bool
    @Environment(\.colorScheme) private var colorScheme
    @State private var wasActive = false

    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isActive)) { timeline in
            let pulse = isActive ? PokesUnseenEmphasis.pulse(at: timeline.date) : 0
            let sweep = isActive ? PokesUnseenEmphasis.sweep(at: timeline.date) : 0
            content
                .shadow(
                    color: PokesUnseenEmphasis.warmAccentColor(
                        opacity: isActive
                            ? (colorScheme == .dark ? 0.14 + 0.22 * pulse : 0.10 + 0.16 * pulse)
                            : 0
                    ),
                    radius: isActive ? 8 + 5 * pulse : 0,
                    y: isActive ? 2 : 0
                )
                .background {
                    if isActive {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(
                                RadialGradient(
                                    colors: [
                                        PokesUnseenEmphasis.warmAccentColor(
                                            opacity: colorScheme == .dark ? 0.16 + 0.14 * pulse : 0.11 + 0.12 * pulse
                                        ),
                                        FGColor.accentBlue.opacity(colorScheme == .dark ? 0.08 + 0.06 * pulse : 0.06 + 0.05 * pulse),
                                        Color.clear
                                    ],
                                    center: .center,
                                    startRadius: 6,
                                    endRadius: 130
                                )
                            )
                            .padding(-8)
                            .blur(radius: 10)
                            .allowsHitTesting(false)
                    }
                }
                .overlay {
                    if isActive {
                        GeometryReader { proxy in
                            let sweepX = -0.35 + 1.7 * sweep
                            LinearGradient(
                                colors: [
                                    Color.clear,
                                    Color.white.opacity(colorScheme == .dark ? 0.06 : 0.14),
                                    PokesUnseenEmphasis.warmAccentColor(opacity: colorScheme == .dark ? 0.10 : 0.08),
                                    Color.white.opacity(colorScheme == .dark ? 0.04 : 0.10),
                                    Color.clear
                                ],
                                startPoint: UnitPoint(x: sweepX - 0.22, y: 0),
                                endPoint: UnitPoint(x: sweepX + 0.22, y: 1)
                            )
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .blendMode(.overlay)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .allowsHitTesting(false)
                    }
                }
                .overlay {
                    if isActive {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        PokesUnseenEmphasis.warmAccentColor(opacity: 0.38 + 0.32 * pulse),
                                        FGColor.accentBlue.opacity(0.18 + 0.14 * pulse),
                                        PokesUnseenEmphasis.warmAccentDeepColor(opacity: 0.28 + 0.24 * pulse)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1.05 + 0.65 * pulse
                            )
                            .allowsHitTesting(false)
                    }
                }
        }
        .onAppear {
            wasActive = isActive
            DebugLogGate.debug("[PokesCardAnimation] active=\(isActive)")
        }
        .onChange(of: isActive) { _, active in
            DebugLogGate.debug("[PokesCardAnimation] active=\(active)")
            if wasActive, !active {
                DebugLogGate.debug("[PokesCardAnimation] acknowledged stopAnimation")
            }
            wasActive = active
        }
    }
}

/// Subtle emphasis on the Pokes title row (label + wave icon).
struct PokesUnseenTitleRowEmphasisModifier: ViewModifier {
    let isActive: Bool
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isActive)) { timeline in
            let pulse = isActive ? PokesUnseenEmphasis.pulse(at: timeline.date) : 0
            content
                .shadow(
                    color: PokesUnseenEmphasis.warmAccentColor(opacity: isActive ? 0.10 + 0.14 * pulse : 0),
                    radius: isActive ? 3 + 2 * pulse : 0
                )
                .opacity(isActive ? 0.92 + 0.08 * pulse : 1)
        }
    }
}

/// Soft shimmer on the wave icon while unseen pokes are present.
struct PokesUnseenWaveIconEmphasisModifier: ViewModifier {
    let isActive: Bool
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isActive)) { timeline in
            let pulse = isActive ? PokesUnseenEmphasis.pulse(at: timeline.date) : 0
            content
                .foregroundStyle(
                    isActive
                        ? AnyShapeStyle(
                            LinearGradient(
                                colors: [
                                    FGColor.accentBlue,
                                    PokesUnseenEmphasis.warmAccentColor(opacity: 0.85 + 0.15 * pulse)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        : AnyShapeStyle(FGColor.accentBlue)
                )
                .shadow(
                    color: PokesUnseenEmphasis.warmAccentColor(opacity: isActive ? 0.22 + 0.28 * pulse : 0),
                    radius: isActive ? 3 + 3 * pulse : 0
                )
                .overlay {
                    if isActive {
                        Circle()
                            .fill(PokesUnseenEmphasis.warmAccentColor(opacity: 0.12 + 0.18 * pulse))
                            .frame(width: 15, height: 15)
                            .blur(radius: 4)
                            .allowsHitTesting(false)
                    }
                }
        }
    }
}

/// Gentle emphasis on the "New" pill while unseen pokes are present.
struct PokesUnseenNewPillEmphasisModifier: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isActive)) { timeline in
            let pulse = isActive ? PokesUnseenEmphasis.pulse(at: timeline.date) : 0
            content
                .opacity(isActive ? 0.88 + 0.12 * pulse : 1)
                .shadow(
                    color: PokesUnseenEmphasis.warmAccentColor(opacity: isActive ? 0.20 + 0.22 * pulse : 0),
                    radius: isActive ? 4 + 2 * pulse : 0,
                    y: 0.5
                )
        }
    }
}

extension View {
    func pokesUnseenHighlightsEmphasis(isActive: Bool) -> some View {
        modifier(PokesUnseenHighlightsEmphasisModifier(isActive: isActive))
    }

    func pokesUnseenTitleRowEmphasis(isActive: Bool) -> some View {
        modifier(PokesUnseenTitleRowEmphasisModifier(isActive: isActive))
    }

    func pokesUnseenWaveIconEmphasis(isActive: Bool) -> some View {
        modifier(PokesUnseenWaveIconEmphasisModifier(isActive: isActive))
    }

    func pokesUnseenNewPillEmphasis(isActive: Bool) -> some View {
        modifier(PokesUnseenNewPillEmphasisModifier(isActive: isActive))
    }
}

/// Subtle unseen-pokes glow dot for profile avatars (no count, no motion).
struct PokesUnseenAvatarBadge: View {
    enum Style {
        case tab
        case profileHero

        var dotSize: CGFloat {
            switch self {
            case .tab: return 9
            case .profileHero: return 11
            }
        }

        var glowSize: CGFloat {
            switch self {
            case .tab: return 14
            case .profileHero: return 18
            }
        }
    }

    let style: Style
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 1, green: 0.44, blue: 0.12).opacity(colorScheme == .dark ? 0.50 : 0.38),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: style.glowSize / 2
                    )
                )
                .frame(width: style.glowSize, height: style.glowSize)

            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 1, green: 0.52, blue: 0.20),
                            Color(red: 0.97, green: 0.26, blue: 0.11),
                            Color(red: 0.90, green: 0.17, blue: 0.09)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: style.dotSize, height: style.dotSize)
                .overlay {
                    Circle()
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.94),
                                    Color.white.opacity(colorScheme == .dark ? 0.50 : 0.72)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.15
                        )
                }
                .shadow(
                    color: Color(red: 1, green: 0.34, blue: 0.08).opacity(colorScheme == .dark ? 0.42 : 0.30),
                    radius: 3,
                    y: 0.5
                )
        }
        .accessibilityHidden(true)
    }
}
