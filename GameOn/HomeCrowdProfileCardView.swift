import SwiftUI

/// Premium Home Crowd identity card (public + self profile). Always shown; `summary` nil renders empty state.
struct HomeCrowdProfileCardView: View {
    let summary: HomeCrowdVenueSummary?
    let isSelfProfile: Bool
    var onExploreVenue: (() -> Void)? = nil
    var onChangeHomeCrowd: (() -> Void)? = nil
    var onChooseHomeCrowd: (() -> Void)? = nil
    @Environment(\.colorScheme) private var colorScheme

    private let cardHeight: CGFloat = 112
    private let imageSide: CGFloat = 86

    private var subtitleLine: String? {
        guard let summary else { return nil }
        if let since = HomeCrowdSinceFormatter.regularSinceLine(from: summary.setAtRaw)
            ?? HomeCrowdSinceFormatter.homeCrowdSinceLine(from: summary.setAtRaw) {
            return since
        }
        if !summary.locationLabel.isEmpty {
            return summary.locationLabel
        }
        return nil
    }

    private var fanCountLine: String? {
        guard let summary else { return nil }
        if isSelfProfile {
            return HomeCrowdFanCountFormatter.selfLine(count: summary.fanCount)
        }
        return HomeCrowdFanCountFormatter.publicLine(count: summary.fanCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let summary {
                if isSelfProfile {
                    selfProfilePopulatedBody(summary)
                        .frame(height: cardHeight)
                } else {
                    publicProfilePopulatedBody(summary)
                }
            } else {
                emptyCardBody
                    .frame(height: cardHeight)
            }
        }
        .animation(.easeInOut(duration: 0.28), value: summary?.venueId)
        .onAppear {
#if DEBUG
            print("[ProfileHierarchyDebug] homeCrowdCompactCard=true")
            print("[ProfileHierarchyDebug] homeCrowdCardHeight=\(Int(cardHeight))")
            print("[ProfileHierarchyDebug] homeCrowdCardHasVenue=\(summary != nil)")
#endif
        }
    }

    // MARK: - Populated (self profile)

    private func selfProfilePopulatedBody(_ summary: HomeCrowdVenueSummary) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                homeCrowdTitleLabel

                VStack(alignment: .leading, spacing: 4) {
                    Text(summary.name)
                        .font(.system(size: 17, weight: .heavy, design: .rounded))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                        .layoutPriority(1)

                    if let subtitleLine {
                        Text(subtitleLine)
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .lineLimit(1)
                    }

                    if let crowdLine = compactCrowdSubtitle(summary) {
                        Text(crowdLine)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(FGColor.mutedText(colorScheme))
                            .lineLimit(1)
                    }
                }

                if isSelfProfile, onExploreVenue != nil || onChangeHomeCrowd != nil {
                    compactActionRow
                        .padding(.top, 1)
                }
            }
            .padding(.vertical, 12)
            .padding(.leading, 14)
            .padding(.trailing, 2)
            .frame(maxWidth: .infinity, alignment: .leading)

            populatedVenueImageColumn(summary)
                .frame(width: imageSide, height: imageSide)
                .padding(.trailing, 12)
        }
        .homeCrowdCardChrome(colorScheme: colorScheme, accent: homeCrowdAccent)
    }

    // MARK: - Populated (public profile)

    private func publicProfilePopulatedBody(_ summary: HomeCrowdVenueSummary) -> some View {
        Button {
            onExploreVenue?()
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                homeCrowdTitleLabel

                HStack(alignment: .center, spacing: 12) {
                    publicVenueThumbnail(summary)
                        .frame(width: publicImageSide, height: publicImageSide)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(summary.name)
                            .font(.system(size: 16, weight: .heavy, design: .rounded))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .lineLimit(2)
                            .minimumScaleFactor(0.84)
                            .multilineTextAlignment(.leading)

                        if let sinceLine = HomeCrowdSinceFormatter.regularSinceLine(from: summary.setAtRaw) {
                            Text(sinceLine)
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                                .lineLimit(1)
                        }

                        if let localFansLine = HomeCrowdFanCountFormatter.localFansLine(count: summary.fanCount) {
                            Text(localFansLine)
                                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                                .foregroundStyle(FGColor.mutedText(colorScheme))
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(spacing: 8) {
                        HomeCrowdShieldStarBadge(diameter: 30, visualState: .active)

                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(FGColor.mutedText(colorScheme).opacity(0.85))
                    }
                    .padding(.trailing, 2)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(onExploreVenue == nil)
        .accessibilityLabel("Open \(summary.name) venue")
        .accessibilityHint("Opens this fan's Home Crowd venue in Discover")
        .homeCrowdCardChrome(colorScheme: colorScheme, accent: homeCrowdAccent)
    }

    private var publicImageSide: CGFloat { 72 }

    @ViewBuilder
    private func publicVenueThumbnail(_ summary: HomeCrowdVenueSummary) -> some View {
        Group {
            if let raw = summary.thumbnailURL, let url = URL(string: raw) {
                DiscoverCachedRemoteImage(url: url, contentMode: .fill) {
                    homeCrowdPlaceholderVisual
                }
                .id(summary.venueId)
            } else {
                homeCrowdPlaceholderVisual
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    Color.white.opacity(colorScheme == .dark ? 0.18 : 0.72),
                    lineWidth: 1
                )
        }
        .shadow(color: homeCrowdAccent.opacity(colorScheme == .dark ? 0.22 : 0.12), radius: 8, y: 3)
    }

    private func compactCrowdSubtitle(_ summary: HomeCrowdVenueSummary) -> String? {
        if let fanCountLine, !fanCountLine.isEmpty {
            return fanCountLine
        }
        if isSelfProfile {
            return "Your match-day crowd"
        }
        return "This fan's home crowd"
    }

    private func populatedVenueImageColumn(_ summary: HomeCrowdVenueSummary) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let raw = summary.thumbnailURL, let url = URL(string: raw) {
                    DiscoverCachedRemoteImage(url: url, contentMode: .fill) {
                        homeCrowdPlaceholderVisual
                    }
                    .id(summary.venueId)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                } else {
                    homeCrowdPlaceholderVisual
                }
            }
            .frame(width: imageSide, height: imageSide)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            LinearGradient(
                colors: [
                    Color.black.opacity(0.02),
                    Color.black.opacity(0.22),
                    Color.black.opacity(0.48)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(colorScheme == .dark ? 0.34 : 0.82),
                            homeCrowdAccent.opacity(0.34)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.2
                )

            HomeCrowdShieldStarBadge(diameter: 24, visualState: .active)
                .padding(7)
        }
        .shadow(color: homeCrowdAccent.opacity(colorScheme == .dark ? 0.28 : 0.16), radius: 12, y: 4)
    }

    // MARK: - Empty

    private var emptyCardBody: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                homeCrowdTitleLabel

                VStack(alignment: .leading, spacing: 5) {
                    Text(emptyMainLine)
                        .font(.system(size: 16, weight: .heavy, design: .rounded))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(2)
                        .minimumScaleFactor(0.84)
                        .fixedSize(horizontal: false, vertical: true)

                    if isSelfProfile {
                        Text("Pick your go-to watch spot or local sports crowd.")
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if isSelfProfile, let onChooseHomeCrowd {
                    chooseHomeCrowdCTA(action: onChooseHomeCrowd)
                        .padding(.top, 1)
                }
            }
            .padding(.vertical, 12)
            .padding(.leading, 14)
            .padding(.trailing, 2)
            .frame(maxWidth: .infinity, alignment: .leading)

            emptyPlaceholderColumn
                .frame(width: imageSide, height: imageSide)
                .padding(.trailing, 12)
        }
        .homeCrowdCardChrome(colorScheme: colorScheme, accent: homeCrowdAccent)
    }

    private var emptyMainLine: String {
        if isSelfProfile {
            return "Choose your sports home"
        }
        return "This fan hasn't picked a Home Crowd yet."
    }

    private var emptyPlaceholderColumn: some View {
        ZStack {
            homeCrowdPlaceholderVisual
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            RadialGradient(
                colors: [
                    homeCrowdAccent.opacity(colorScheme == .dark ? 0.28 : 0.22),
                    Color.clear
                ],
                center: .center,
                startRadius: 8,
                endRadius: 72
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            HomeCrowdShieldStarBadge(diameter: 48, visualState: .active)
                .shadow(color: homeCrowdAccent.opacity(0.45), radius: 14, y: 4)
        }
    }

    // MARK: - Shared visuals

    private var homeCrowdTitleLabel: some View {
        Text("HOME CROWD")
            .font(.system(size: 9.5, weight: .heavy, design: .rounded))
            .foregroundStyle(homeCrowdAccent)
            .tracking(1.08)
    }

    private var homeCrowdPlaceholderVisual: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.62, green: 0.38, blue: 0.96),
                    Color(red: 0.34, green: 0.42, blue: 0.94),
                    Color(red: 0.18, green: 0.28, blue: 0.72)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            HomeCrowdShieldStarBadge(diameter: 52, visualState: .active)
                .shadow(color: homeCrowdAccent.opacity(0.35), radius: 10, y: 4)
        }
    }

    private func homeCrowdAvatarStack(_ summary: HomeCrowdVenueSummary) -> some View {
        let avatars = summary.resolvedFanAvatars
        let shown = avatars.prefix(4)
        let othersAtVenue = max(0, summary.fanCount - 1)
        let overflow = max(0, othersAtVenue - shown.count)

        return HStack(spacing: -11) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, fan in
                UserAvatarView(
                    avatarThumbnailURL: fan.avatarURL,
                    avatarURL: fan.avatarURL ?? "",
                    avatarDisplayRefreshToken: UserAvatarView.stableRefreshToken(
                        userId: fan.userId,
                        thumbnailURL: fan.avatarURL,
                        avatarURL: fan.avatarURL
                    ),
                    displayName: fan.displayName,
                    email: "",
                    size: 30,
                    fallbackStyle: .lightOnWhiteChrome,
                    imagePlaceholderTint: FGColor.accentBlue
                )
                .overlay(Circle().strokeBorder(Color.white, lineWidth: 2.5))
                .shadow(color: Color.black.opacity(0.12), radius: 3, y: 1)
                .zIndex(Double(index))
            }
            if overflow > 0 {
                Text("+\(overflow)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .frame(width: 30, height: 30)
                    .background {
                        Circle()
                            .fill(Color.white.opacity(colorScheme == .dark ? 0.14 : 0.96))
                    }
                    .overlay(Circle().strokeBorder(Color.white, lineWidth: 2.5))
                    .shadow(color: Color.black.opacity(0.10), radius: 3, y: 1)
            }
        }
    }

    // MARK: - Actions

    private var compactActionRow: some View {
        HStack(spacing: 7) {
            if let onExploreVenue {
                homeCrowdCapsuleButton(title: "Open Venue", icon: "arrow.up.right", isPrimary: true, action: onExploreVenue)
            }
            if let onChangeHomeCrowd {
                homeCrowdIconButton(showsHomeCrowdBadge: true, action: onChangeHomeCrowd)
            }
        }
    }

    private func chooseHomeCrowdCTA(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                HomeCrowdShieldStarBadge(diameter: 18, visualState: .active)
                Text("Choose Home Crowd")
                    .font(.system(size: 11.5, weight: .heavy, design: .rounded))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 30)
            .padding(.horizontal, 10)
            .background {
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.58, green: 0.36, blue: 0.98),
                                Color(red: 0.42, green: 0.34, blue: 0.94)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .shadow(color: homeCrowdAccent.opacity(0.35), radius: 10, y: 4)
            }
        }
        .buttonStyle(.plain)
    }

    private func homeCrowdCapsuleButton(
        title: String,
        icon: String? = nil,
        showsHomeCrowdBadge: Bool = false,
        isPrimary: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if showsHomeCrowdBadge {
                    HomeCrowdShieldStarBadge(diameter: 16, visualState: .active)
                } else if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .bold))
                }
                Text(title)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(isPrimary ? .white : FGColor.accentBlue)
            .frame(minHeight: 30)
            .padding(.horizontal, 11)
            .background {
                Capsule(style: .continuous)
                    .fill(isPrimary ? FGColor.accentBlue : Color.clear)
                    .background {
                        if !isPrimary {
                            Capsule(style: .continuous)
                                .fill(.ultraThinMaterial)
                                .background {
                                    Capsule(style: .continuous)
                                        .fill(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.12 : 0.08))
                                }
                        }
                    }
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(isPrimary ? Color.white.opacity(0.20) : FGColor.divider(colorScheme).opacity(0.75), lineWidth: 0.75)
            }
        }
        .buttonStyle(.plain)
    }

    private func homeCrowdIconButton(
        showsHomeCrowdBadge: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if showsHomeCrowdBadge {
                    HomeCrowdShieldStarBadge(diameter: 18, visualState: .active)
                } else {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .bold))
                }
            }
            .frame(width: 30, height: 30)
            .background {
                Circle()
                    .fill(.ultraThinMaterial)
                    .background {
                        Circle()
                            .fill(homeCrowdAccent.opacity(colorScheme == .dark ? 0.15 : 0.10))
                    }
            }
            .overlay {
                Circle()
                    .strokeBorder(FGColor.divider(colorScheme).opacity(0.70), lineWidth: 0.75)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Change Home Crowd")
    }

    private var homeCrowdAccent: Color {
        Color(red: 0.78, green: 0.62, blue: 1.0)
    }
}

// MARK: - Card chrome

private extension View {
    func homeCrowdCardChrome(colorScheme: ColorScheme, accent: Color) -> some View {
        self
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .background {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(colorScheme == .dark ? 0.14 : 0.98),
                                        Color.white.opacity(colorScheme == .dark ? 0.08 : 0.94),
                                        accent.opacity(colorScheme == .dark ? 0.06 : 0.04)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(colorScheme == .dark ? 0.22 : 0.92),
                                accent.opacity(0.18)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.85
                    )
            }
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.24 : 0.07), radius: 14, y: 7)
            .shadow(color: accent.opacity(colorScheme == .dark ? 0.12 : 0.06), radius: 18, y: 4)
    }
}
