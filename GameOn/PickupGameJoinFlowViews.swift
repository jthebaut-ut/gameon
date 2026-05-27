import SwiftUI

// MARK: - Join request withdraw (Calendar / Following / detail)

struct PickupJoinWithdrawConfirmState: Identifiable {
    let id = UUID()
    let requestId: UUID
    let pickupGameId: UUID
    let intent: PickupJoinWithdrawIntent

    enum PickupJoinWithdrawIntent {
        case pending
        case approved
        case declined

        var alertTitle: String {
            switch self {
            case .pending: return "Withdraw your request to join this game?"
            case .approved: return "Tell the organizer you can’t make it?"
            case .declined: return "Remove this game from your list?"
            }
        }

        var alertMessage: String {
            switch self {
            case .pending:
                return "You can request to join again later if the game still has openings."
            case .approved:
                return "Your spot will be freed for another player."
            case .declined:
                return "This hides the declined request from your Playing and Calendar pickup lists."
            }
        }
    }
}

// MARK: - Pickup “started” visuals (shared)

/// Wraps a sport glyph with a small, neutral “Started” tag (not alarming).
struct PickupGameStartedSportGlyphFrame<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let showStarted: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack(alignment: .topTrailing) {
            content()
            if showStarted {
                Text("Started")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.primary.opacity(colorScheme == .dark ? 0.22 : 0.07))
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(FGColor.divider(colorScheme).opacity(colorScheme == .dark ? 0.55 : 0.4), lineWidth: 1)
                    )
                    .offset(x: 5, y: -4)
                    .accessibilityLabel("Game already started")
            }
        }
    }
}

/// One-line caption for list / detail headers.
struct PickupGameStartedLineCaption: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text("Game already started")
            .font(FGTypography.caption.weight(.medium))
            .foregroundStyle(FGColor.secondaryText(colorScheme))
            .accessibilityLabel("Game already started")
    }
}

/// Stable token for presenting pickup detail from Discover (`Identifiable` for `.sheet(item:)`).
struct PickupDetailNavigationToken: Identifiable, Equatable, Hashable {
    let id: UUID
}

/// Discover → Pickup mode: full detail + join request entry (Phase 2).
struct DiscoverPickupGameDetailSheet: View {
    @ObservedObject var viewModel: MapViewModel
    let gameId: UUID

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var showJoinComposer = false
    @State private var showInviteComposer = false
    @State private var joinError: String?
    @State private var isCancellingRequest = false
    @State private var withdrawConfirm: PickupJoinWithdrawConfirmState?

    private var game: PickupGameRow? {
        viewModel.resolvedPickupGameRow(for: gameId)
    }

    private var isCreator: Bool {
        guard let uid = viewModel.currentUserAuthId, let g = game else { return false }
        return g.creator_user_id == uid
    }

    private var myRequest: PickupGameRequestRow? {
        viewModel.pickupMyLatestJoinRequestByGameId[gameId]
    }

    private var showPickupOrganizerRatingCard: Bool {
        guard !isCreator, let g = game, let uid = viewModel.currentUserAuthId else { return false }
        guard g.creator_user_id != uid else { return false }
        guard let req = myRequest, req.requester_user_id == uid else { return false }
        guard req.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "approved" else { return false }
        guard g.isPickupCreatorRatingPromptEligible() else { return false }
        return !viewModel.hasSubmittedPickupCreatorRating(for: gameId)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let g = game {
                    if viewModel.isGuestDiscoverMode {
                        guestDiscoverPickupDetail(for: g)
                    } else {
                        detailContent(for: g)
                    }
                } else {
                    ContentUnavailableView(
                        "Pickup unavailable",
                        systemImage: "person.3.fill",
                        description: Text("This game may be full or no longer listed.")
                    )
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                }
            }
            .navigationTitle("Pickup game")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showJoinComposer) {
                if let g = game {
                    PickupGameJoinRequestComposerSheet(viewModel: viewModel, pickupGame: g) {
                        showJoinComposer = false
                    }
                }
            }
            .sheet(isPresented: $showInviteComposer) {
                if let g = game {
                    PickupGameInviteFriendsSheet(viewModel: viewModel, game: g)
                }
            }
            .task(id: gameId) {
                if viewModel.isGuestDiscoverMode {
                    if let g = viewModel.resolvedPickupGameRow(for: gameId) {
                        await viewModel.loadPickupOrganizerTrustStatsForPickupDetail(creatorUserId: g.creator_user_id)
                    }
                    return
                }
                if let cid = game?.creator_user_id {
                    await viewModel.loadPickupCreatorDisplayNameIfNeeded(creatorUserId: cid)
                }
                await viewModel.loadMyLatestJoinRequestForPickupGame(pickupGameId: gameId)
                if let g = viewModel.resolvedPickupGameRow(for: gameId) {
                    await viewModel.refreshPickupCreatorRatingUIContext(pickupGameId: gameId, creatorUserId: g.creator_user_id)
                    let now = Date()
                    let creator = viewModel.currentUserAuthId == g.creator_user_id
                    let actions: String
                    if creator {
                        actions = g.hasPickupGameStarted(now: now)
                            ? "manage_requests,roster_capacity"
                            : "full_edit_before_start"
                    } else {
                        actions = g.hasPickupGameStarted(now: now) ? "view_join_state" : "join_request"
                    }
                    PickupGameStartedStateDebug.log(row: g, now: now, allowedActions: actions)
                }
            }
            .onChange(of: viewModel.pickupGamesForDiscoverMap.count) { _, _ in
                guard !viewModel.isGuestDiscoverMode else { return }
                Task { await viewModel.loadMyLatestJoinRequestForPickupGame(pickupGameId: gameId) }
            }
            .onChange(of: viewModel.pickupJoinRequestUiRevision) { _, _ in
                guard !viewModel.isGuestDiscoverMode else { return }
                Task { await viewModel.loadMyLatestJoinRequestForPickupGame(pickupGameId: gameId) }
            }
            .alert(item: $withdrawConfirm) { state in
                Alert(
                    title: Text(state.intent.alertTitle),
                    message: Text(state.intent.alertMessage),
                    primaryButton: .destructive(Text("Yes, withdraw")) {
                        Task { await performPickupJoinWithdraw(state) }
                    },
                    secondaryButton: .cancel()
                )
            }
        }
    }

    /// Discover guest session (``MapViewModel/isGuestDiscoverMode``): hides address, time, counts, join, and organizer identity; still shows **public** organizer trust (RPC aggregates only).
    @ViewBuilder
    private func guestDiscoverPickupDetail(for g: PickupGameRow) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FGSpacing.lg) {
                VStack(alignment: .leading, spacing: FGSpacing.sm) {
                    GameFormatBadgeView(format: g.gameFormat, colorScheme: colorScheme)
                    Text(g.title)
                        .font(FGTypography.sectionTitle)
                        .foregroundStyle(pickupDetailMainInk)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(g.sport) · \(g.playEnvironmentEnum.shortLabel)")
                        .font(FGTypography.metadata.weight(.medium))
                        .foregroundStyle(pickupDetailSubInk)
                }
                .padding(FGSpacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background { pickupGlassBackground(cornerRadius: FGRadius.large) }
                .clipShape(RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous))
                .overlay { pickupGlassStroke(cornerRadius: FGRadius.large) }

                PickupCreatorTrustLineView(
                    stats: viewModel.pickupCreatorTrustStats(for: g.creator_user_id),
                    detailAlwaysVisible: true
                )
                .padding(.top, FGSpacing.xs)

                DiscoverGuestGameLockCard {
                    viewModel.discoverPresentFanUserAuthSheet(openRegisterMode: false)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(FGSpacing.lg)
        }
        .scrollContentBackground(.hidden)
        .fanGeoScreenBackground()
    }

    @ViewBuilder
    private func detailContent(for g: PickupGameRow) -> some View {
        let locationLine = [g.address, g.city, g.state]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        let creatorLabel = viewModel.pickupCreatorDisplayLabel(for: g.creator_user_id)
        let subtitleLine = "\(g.sport) • \(g.playEnvironmentEnum.shortLabel) • \(g.skillLevelEnum.displayTitle)"
        let showStarted = g.hasPickupGameStarted()

        ScrollView {
            VStack(alignment: .leading, spacing: FGSpacing.md) {
                pickupHeroCard(
                    g: g,
                    locationLine: locationLine,
                    subtitleLine: subtitleLine,
                    showStarted: showStarted
                )

                if isCreator, g.isPickupGameInvitable() {
                    pickupInviteActionRow(for: g)
                }

                HStack(alignment: .top, spacing: FGSpacing.sm) {
                    pickupStatCard(
                        title: "Spots",
                        value: "\(g.pickupOpenSlotsRemaining) left",
                        systemImage: "person.3.sequence",
                        tint: FGColor.accentBlue
                    )
                    pickupStatCard(
                        title: "Players",
                        value: "\(g.playersNeededClamped) needed",
                        systemImage: "person.badge.plus",
                        tint: FGColor.accentGreen
                    )
                    pickupStatCard(
                        title: "Approved",
                        value: "\(g.approvedJoinCount)",
                        systemImage: "checkmark.circle.fill",
                        tint: FGColor.accentYellow
                    )
                }

                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: FGSpacing.sm), GridItem(.flexible(), spacing: FGSpacing.sm)],
                    spacing: FGSpacing.sm
                ) {
                    pickupDetailTile(
                        title: "Who’s welcome",
                        value: g.participantPreferenceEnum.displayTitle,
                        systemImage: "person.2.fill"
                    )
                    pickupDetailTile(
                        title: "Cost",
                        value: g.entryFeeDisplayLine,
                        systemImage: "dollarsign.circle.fill"
                    )
                    pickupOrganizerDetailTile(g: g, creatorLabel: creatorLabel)
                        .gridCellColumns(2)
                    pickupDetailTile(
                        title: "Play",
                        value: g.playEnvironmentEnum.displayTitle,
                        systemImage: "sportscourt.fill"
                    )
                        .gridCellColumns(2)
                }

                let desc = g.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !desc.isEmpty {
                    Text(desc)
                        .font(FGTypography.body)
                        .foregroundStyle(pickupDetailMainInk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(FGSpacing.md)
                        .background { pickupGlassBackground(cornerRadius: FGRadius.large) }
                        .clipShape(RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                                .strokeBorder(FGColor.divider(colorScheme).opacity(colorScheme == .dark ? 0.5 : 0.35), lineWidth: 1)
                        }
                }

                if isCreator {
                    pickupInfoBanner(text: "You’re organizing this game.")
                }

                if showPickupOrganizerRatingCard {
                    PickupCreatorRatingPromptCard(viewModel: viewModel, game: g)
                }

                joinSection(for: g)

                if let joinError, !joinError.isEmpty {
                    Text(joinError)
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.dangerRed)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(FGSpacing.lg)
        }
        .scrollContentBackground(.hidden)
        .fanGeoScreenBackground()
    }

    private var pickupDetailMainInk: Color {
        colorScheme == .dark ? Color.white.opacity(0.92) : FGColor.primaryText(colorScheme)
    }

    private var pickupDetailSubInk: Color {
        colorScheme == .dark ? Color.white.opacity(0.72) : FGColor.secondaryText(colorScheme)
    }

    @ViewBuilder
    private func pickupGlassBackground(cornerRadius: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
            LinearGradient(
                colors: [
                    Color.black.opacity(colorScheme == .dark ? 0.38 : 0.07),
                    Color.black.opacity(colorScheme == .dark ? 0.18 : 0.03)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    private func pickupGlassStroke(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(FGColor.divider(colorScheme).opacity(colorScheme == .dark ? 0.55 : 0.4), lineWidth: 1)
    }

    private func pickupStatCard(title: String, value: String, systemImage: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(FGTypography.caption.weight(.semibold))
                    .foregroundStyle(pickupDetailSubInk)
            }
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(pickupDetailMainInk)
                .lineLimit(2)
                .minimumScaleFactor(0.78)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, FGSpacing.sm + 2)
        .padding(.vertical, FGSpacing.sm + 2)
        .background { pickupGlassBackground(cornerRadius: FGRadius.medium) }
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
        .overlay { pickupGlassStroke(cornerRadius: FGRadius.medium) }
    }

    private func pickupDetailTile(title: String, value: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.95 : 0.88))
                Text(title)
                    .font(FGTypography.caption.weight(.semibold))
                    .foregroundStyle(pickupDetailSubInk)
            }
            Text(value)
                .font(FGTypography.metadata.weight(.semibold))
                .foregroundStyle(pickupDetailMainInk)
                .lineLimit(3)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(FGSpacing.sm + 2)
        .background { pickupGlassBackground(cornerRadius: FGRadius.medium) }
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
        .overlay { pickupGlassStroke(cornerRadius: FGRadius.medium) }
    }

    private func pickupOrganizerDetailTile(g: PickupGameRow, creatorLabel: String?) -> some View {
        let uid = g.creator_user_id
        let value = creatorLabel ?? "—"
        let displayForAvatar = creatorLabel ?? ""
        let cachedEmail = viewModel.pickupOrganizerEmailForDetail(userId: uid)
        let emailLine = !cachedEmail.isEmpty ? cachedEmail : (g.creator_email ?? "")
        let thumb = viewModel.pickupOrganizerAvatarThumbnailForDetail(userId: uid)
        let full = viewModel.pickupOrganizerAvatarFullForDetail(userId: uid)
        let token = viewModel.pickupOrganizerAvatarRefreshTokenForDetail(userId: uid)
        let avatarFallback: UserAvatarView.FallbackStyle = colorScheme == .dark ? .darkCardTranslucent : .lightOnWhiteChrome

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.95 : 0.88))
                        Text("Organizer")
                            .font(FGTypography.caption.weight(.semibold))
                            .foregroundStyle(pickupDetailSubInk)
                    }
                    Text(value)
                        .font(FGTypography.metadata.weight(.semibold))
                        .foregroundStyle(pickupDetailMainInk)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                PublicProfileAvatarTap(userId: uid, context: "pickup_detail_organizer") {
                    UserAvatarView(
                        avatarThumbnailURL: thumb,
                        avatarURL: full,
                        avatarDisplayRefreshToken: token,
                        displayName: displayForAvatar,
                        email: emailLine,
                        size: 48,
                        fallbackStyle: avatarFallback,
                        imagePlaceholderTint: colorScheme == .dark ? .white.opacity(0.75) : nil
                    )
                }
            }

            pickupOrganizerTrustBadge(stats: viewModel.pickupCreatorTrustStats(for: uid))
                .padding(.top, 2)
                .padding(.bottom, 4)
        }
        .padding(.horizontal, FGSpacing.sm + 2)
        .padding(.top, FGSpacing.sm + 2)
        .padding(.bottom, FGSpacing.md)
        .background { pickupGlassBackground(cornerRadius: FGRadius.medium) }
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
        .overlay { pickupGlassStroke(cornerRadius: FGRadius.medium) }
    }

    /// Full-width pill highlighting organizer trust (detail sheet only; stats from existing cache / RPC loaders).
    @ViewBuilder
    private func organizerTrustBadgeShell<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(FGColor.accentYellow.opacity(colorScheme == .dark ? 0.22 : 0.16))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(FGColor.accentYellow.opacity(colorScheme == .dark ? 0.52 : 0.4), lineWidth: 1.5)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private func pickupOrganizerTrustBadge(stats: PickupCreatorPublicRatingStats?) -> some View {
        let starTint = FGColor.accentYellow
        if let stats {
            if stats.ratingCount > 0 {
                let reviewWords = stats.ratingCount == 1 ? "1 review" : "\(stats.ratingCount) reviews"
                organizerTrustBadgeShell {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "star.fill")
                                .font(.title3)
                                .foregroundStyle(starTint)
                            Text(String(format: "%.1f", stats.avgRating))
                                .font(.callout.weight(.bold))
                                .foregroundStyle(pickupDetailMainInk)
                        }
                        Text(reviewWords)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(pickupDetailSubInk)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Organizer rating \(String(format: "%.1f", stats.avgRating)), \(reviewWords)")
            } else {
                organizerTrustBadgeShell {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .center, spacing: 8) {
                            Image(systemName: "star.fill")
                                .font(.title3)
                                .foregroundStyle(starTint)
                            Text("New organizer")
                                .font(.callout.weight(.bold))
                                .foregroundStyle(pickupDetailMainInk)
                        }
                        Text("No ratings yet")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(pickupDetailSubInk)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Organizer is a new organizer, no ratings yet")
            }
        } else {
            organizerTrustBadgeShell {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading organizer trust…")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(pickupDetailSubInk)
                }
            }
            .accessibilityLabel("Loading organizer trust")
        }
    }

    private func pickupInfoBanner(text: String) -> some View {
        HStack(alignment: .center, spacing: FGSpacing.sm) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.title3)
                .foregroundStyle(FGColor.accentBlue)
            Text(text)
                .font(FGTypography.metadata.weight(.medium))
                .foregroundStyle(pickupDetailMainInk)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(FGSpacing.md)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous)
                    .fill(.thinMaterial)
                RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous)
                    .fill(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.12 : 0.08))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous)
                .strokeBorder(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.35 : 0.28), lineWidth: 1)
        }
    }

    private func pickupHeroCard(g: PickupGameRow, locationLine: String, subtitleLine: String, showStarted: Bool) -> some View {
        HStack(alignment: .top, spacing: FGSpacing.md) {
            PickupGameStartedSportGlyphFrame(showStarted: showStarted) {
                SportArtworkIconView(sport: g.sport, diameter: 48)
            }

            VStack(alignment: .leading, spacing: FGSpacing.sm) {
                GameFormatBadgeView(format: g.gameFormat, colorScheme: colorScheme)

                Text(g.title)
                    .font(FGTypography.sectionTitle)
                    .foregroundStyle(pickupDetailMainInk)

                Text(subtitleLine)
                    .font(FGTypography.metadata.weight(.medium))
                    .foregroundStyle(pickupDetailSubInk)

                if showStarted {
                    PickupGameStartedLineCaption()
                }

                if let start = PickupGameModels.parseSupabaseTimestamptz(g.game_start_at) {
                    Text(g.pickupDateWithCompactTimeRange ?? start.formatted(date: .abbreviated, time: .shortened))
                        .font(FGTypography.cardTitle.weight(.semibold))
                        .foregroundStyle(pickupDetailMainInk)
                }

                HStack(alignment: .top, spacing: FGSpacing.md) {
                    VStack(alignment: .leading, spacing: 4) {
                        if !locationLine.isEmpty {
                            Text(locationLine)
                                .font(FGTypography.caption)
                                .foregroundStyle(pickupDetailSubInk)
                                .lineLimit(3)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if let lat = g.latitude, let lon = g.longitude {
                        Button {
                            if let url = URL(string: "http://maps.apple.com/?ll=\(lat),\(lon)&q=Pickup%20game") {
                                openURL(url)
                            }
                        } label: {
                            Label("Directions", systemImage: "map")
                                .font(FGTypography.caption.weight(.semibold))
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(FGColor.accentBlue)
                        .fixedSize()
                    }
                }
            }
        }
        .padding(FGSpacing.lg)
        .background { pickupGlassBackground(cornerRadius: FGRadius.large) }
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous))
        .overlay { pickupGlassStroke(cornerRadius: FGRadius.large) }
    }

    private func pickupInviteActionRow(for g: PickupGameRow) -> some View {
        HStack(spacing: FGSpacing.sm) {
            ShareLink(item: pickupShareText(for: g)) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .font(FGTypography.metadata.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            .tint(FGColor.accentBlue)

            Button {
                showInviteComposer = true
            } label: {
                Label("Invite friends", systemImage: "person.badge.plus")
                    .font(FGTypography.metadata.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            .tint(Color.orange)
        }
        .padding(FGSpacing.sm)
        .background { pickupGlassBackground(cornerRadius: FGRadius.medium) }
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
        .overlay { pickupGlassStroke(cornerRadius: FGRadius.medium) }
    }

    private func pickupShareText(for g: PickupGameRow) -> String {
        var lines = ["Join \(g.title) on FanGeo."]
        if let date = g.pickupDateWithCompactTimeRange {
            lines.append(date)
        }
        let location = [g.address, g.city, g.state]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        if !location.isEmpty {
            lines.append(location)
        }
        return lines.joined(separator: "\n")
    }

    private func labeledRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: FGSpacing.xs) {
            Text(title)
                .font(FGTypography.caption.weight(.semibold))
                .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.68) : FGColor.mutedText(colorScheme))
            Text(value)
                .font(FGTypography.body)
                .foregroundStyle(pickupDetailMainInk)
        }
    }

    @ViewBuilder
    private func joinSection(for g: PickupGameRow) -> some View {
        if !viewModel.isAuthenticatedForSocialFeatures {
            Text("Sign in to request to join this pickup game.")
                .font(FGTypography.caption)
                .foregroundStyle(pickupDetailSubInk)
                .padding(.top, FGSpacing.xs)
        } else if !viewModel.canJoinPickupGames {
            Text(BusinessFanGateCopy.pickupFanOnly)
                .font(FGTypography.caption)
                .foregroundStyle(pickupDetailSubInk)
                .padding(.top, FGSpacing.xs)
        } else if isCreator {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: FGSpacing.sm) {
                if let req = myRequest {
                    labeledRow("Your request", req.statusDisplayTitle)
                    let st = req.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if st == "pending" {
                        Button(role: .destructive) {
#if DEBUG
                            print("[PickupJoinWithdraw] tapped gameId=\(gameId.uuidString.lowercased())")
                            print("[PickupJoinWithdraw] requestId=\(req.id.uuidString.lowercased())")
#endif
                            withdrawConfirm = PickupJoinWithdrawConfirmState(
                                requestId: req.id,
                                pickupGameId: gameId,
                                intent: .pending
                            )
                        } label: {
                            if isCancellingRequest {
                                ProgressView()
                            } else {
                                Text("Withdraw request")
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(Color.red.opacity(0.92))
                        .disabled(isCancellingRequest)
                    } else if st == "approved" {
                        Button(role: .destructive) {
#if DEBUG
                            print("[PickupJoinWithdraw] tapped gameId=\(gameId.uuidString.lowercased())")
                            print("[PickupJoinWithdraw] requestId=\(req.id.uuidString.lowercased())")
#endif
                            withdrawConfirm = PickupJoinWithdrawConfirmState(
                                requestId: req.id,
                                pickupGameId: gameId,
                                intent: .approved
                            )
                        } label: {
                            if isCancellingRequest {
                                ProgressView()
                            } else {
                                Text("Can’t make it")
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(Color.red.opacity(0.92))
                        .disabled(isCancellingRequest)
                    } else if st == "rejected" {
                        Button(role: .destructive) {
#if DEBUG
                            print("[PickupJoinWithdraw] tapped gameId=\(gameId.uuidString.lowercased())")
                            print("[PickupJoinWithdraw] requestId=\(req.id.uuidString.lowercased())")
#endif
                            withdrawConfirm = PickupJoinWithdrawConfirmState(
                                requestId: req.id,
                                pickupGameId: gameId,
                                intent: .declined
                            )
                        } label: {
                            if isCancellingRequest {
                                ProgressView()
                            } else {
                                Text("Remove from list")
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(Color.red.opacity(0.92))
                        .disabled(isCancellingRequest)
                    }
                }
                if shouldShowRequestToJoin(for: g) {
                    Button {
                        joinError = nil
                        showJoinComposer = true
                    } label: {
                        Text("Request to Join")
                            .font(FGTypography.metadata.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(FGColor.accentBlue)
                } else if myRequest == nil, g.isPickupFullForDiscover {
                    Text("No more players needed.")
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(pickupDetailSubInk)
                }
            }
            .padding(.top, FGSpacing.sm)
        }
    }

    private func performPickupJoinWithdraw(_ state: PickupJoinWithdrawConfirmState) async {
        isCancellingRequest = true
        joinError = nil
        defer {
            isCancellingRequest = false
            withdrawConfirm = nil
        }
        do {
            try await viewModel.withdrawMyPickupJoinRequest(requestId: state.requestId, pickupGameId: state.pickupGameId)
        } catch {
            joinError = error.localizedDescription
        }
    }

    private func shouldShowRequestToJoin(for g: PickupGameRow) -> Bool {
        guard !g.isPickupFullForDiscover else { return false }
        guard let req = myRequest else { return true }
        let s = req.status.lowercased()
        return s == "rejected" || s == "cancelled" || s == "withdrawn"
    }
}

struct PickupGameInviteFriendsSheet: View {
    @ObservedObject var viewModel: MapViewModel
    let game: PickupGameRow

    @EnvironmentObject private var chatViewModel: ChatViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var selectedFriendIds: Set<UUID> = []
    @State private var searchText = ""
    @State private var searchResults: [PickupInvitableFanSearchResult] = []
    @State private var inviteStatusByUserId: [UUID: String] = [:]
    @State private var searchTask: Task<Void, Never>?
    @State private var isSearching = false
    @State private var isSending = false
    @State private var errorText: String?

    private var eligibleFriends: [ChatViewModel.FriendDisplay] {
        chatViewModel.friends
            .filter { friend in
                friend.id != viewModel.currentUserAuthId
                    && !chatViewModel.isEitherDirectionBlocked(with: friend.id)
            }
            .sorted {
                $0.preview.displayName.localizedCaseInsensitiveCompare($1.preview.displayName) == .orderedAscending
            }
    }

    private var canSend: Bool {
        !selectedFriendIds.isEmpty && !isSending && game.isPickupGameInvitable()
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                inviteHeader

                List {
                    Section {
                        if eligibleFriends.isEmpty {
                            Text("No friends to invite yet")
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                        } else {
                            ForEach(eligibleFriends) { friend in
                                pickupInviteFriendRow(friend)
                            }
                        }
                    } header: {
                        Text("Friends")
                    } footer: {
                        Text("\(selectedFriendIds.count)/20 selected")
                    }

                    Section {
                        TextField("Search fans by @handle or name", text: $searchText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } header: {
                        Text("Invite non-friends")
                    } footer: {
                        Text("Optional. Search FanGeo users by handle or display name.")
                    }

                    Section {
                        if isSearching {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("Searching fans...")
                                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                            }
                        } else if searchText.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 {
                            Text("Type at least 2 characters to search FanGeo users.")
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                        } else if searchResults.isEmpty {
                            Text("No fans found")
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                        } else {
                            ForEach(searchResults) { result in
                                pickupInviteSearchResultRow(result)
                            }
                        }
                    } header: {
                        Text("Search Results")
                    }
                }
                .scrollContentBackground(.hidden)

                if let errorText, !errorText.isEmpty {
                    Text(errorText)
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.dangerRed)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, FGSpacing.lg)
                        .padding(.vertical, FGSpacing.sm)
                }
            }
            .fanGeoScreenBackground()
            .navigationTitle("Invite friends to play")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await sendInvites() }
                    } label: {
                        if isSending {
                            ProgressView()
                        } else {
                            Text("Send")
                        }
                    }
                    .disabled(!canSend)
                }
            }
            .task {
                if chatViewModel.friends.isEmpty {
                    await chatViewModel.refresh()
                }
                inviteStatusByUserId = await viewModel.loadPickupInviteStatusesByInviteeUserId(gameId: game.id)
            }
            .onChange(of: searchText) { _, newValue in
                scheduleFanSearch(newValue)
            }
            .onDisappear {
                searchTask?.cancel()
            }
        }
    }

    private var inviteHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                SportArtworkIconView(sport: game.sport, diameter: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text(game.title)
                        .font(FGTypography.cardTitle)
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(2)
                    Text("\(game.sport) · \(game.gameFormat.displayTitle)")
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                    if let dateLine = game.pickupDateWithCompactTimeRange {
                        Text(dateLine)
                            .font(FGTypography.caption)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    }
                }
            }
            if !game.isPickupGameInvitable() {
                Text("This game is no longer accepting invites.")
                    .font(FGTypography.caption.weight(.semibold))
                    .foregroundStyle(FGColor.dangerRed)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(FGSpacing.lg)
        .background(.ultraThinMaterial)
    }

    private func pickupInviteFriendRow(_ friend: ChatViewModel.FriendDisplay) -> some View {
        let inviteStatus = inviteStatusByUserId[friend.id]
        let disabled = inviteStatus != nil
        return Button {
            toggleFriend(friend.id)
        } label: {
            HStack(spacing: 12) {
                ProfileAvatarView(preview: friend.preview, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(friend.preview.displayName)
                        .font(FGTypography.body.weight(.semibold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                    if let username = friend.preview.username, !username.isEmpty {
                        Text("@\(username)")
                            .font(FGTypography.caption)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    }
                    if let inviteStatus {
                        pickupInviteStatusBadge(status: inviteStatus)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: disabled ? "checkmark.seal.fill" : (selectedFriendIds.contains(friend.id) ? "checkmark.circle.fill" : "circle"))
                    .font(.title3)
                    .foregroundStyle(disabled ? Color.orange : (selectedFriendIds.contains(friend.id) ? FGColor.accentGreen : FGColor.mutedText(colorScheme)))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.62 : 1)
    }

    private func pickupInviteSearchResultRow(_ result: PickupInvitableFanSearchResult) -> some View {
        let inviteStatus = inviteStatusByUserId[result.user_id]
        let disabled = inviteStatus != nil
        return Button {
            toggleSearchResult(result)
        } label: {
            HStack(spacing: 12) {
                ProfileAvatarView(preview: result.userPreview, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(result.display_name)
                            .font(FGTypography.body.weight(.semibold))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                        if result.is_friend {
                            Text("Friend")
                                .font(FGTypography.caption.weight(.bold))
                                .foregroundStyle(FGColor.accentGreen)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(FGColor.accentGreen.opacity(0.12), in: Capsule())
                        }
                    }
                    if !result.displayHandle.isEmpty {
                        Text(result.displayHandle)
                            .font(FGTypography.caption)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    }
                    if let inviteStatus {
                        pickupInviteStatusBadge(status: inviteStatus)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: disabled ? "checkmark.seal.fill" : (selectedFriendIds.contains(result.user_id) ? "checkmark.circle.fill" : "circle"))
                    .font(.title3)
                    .foregroundStyle(disabled ? Color.orange : (selectedFriendIds.contains(result.user_id) ? FGColor.accentGreen : FGColor.mutedText(colorScheme)))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.62 : 1)
    }

    private func toggleFriend(_ id: UUID) {
        guard inviteStatusByUserId[id] == nil else { return }
        if selectedFriendIds.contains(id) {
            selectedFriendIds.remove(id)
        } else if selectedFriendIds.count < 20 {
            selectedFriendIds.insert(id)
        } else {
            errorText = "You can invite up to 20 people per game."
        }
    }

    private func toggleSearchResult(_ result: PickupInvitableFanSearchResult) {
        guard inviteStatusByUserId[result.user_id] == nil else { return }
        let wasSelected = selectedFriendIds.contains(result.user_id)
        toggleFriend(result.user_id)
#if DEBUG
        if !result.is_friend, !wasSelected, selectedFriendIds.contains(result.user_id) {
            print("[PickupInviteDebug] nonFriendInviteSelected=\(result.user_id.uuidString.lowercased())")
        }
#endif
    }

    private func pickupInviteStatusBadge(status: String) -> some View {
        let display = pickupInviteStatusDisplay(status)
        return Text(display.title)
            .font(FGTypography.caption.weight(.semibold))
            .foregroundStyle(display.tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(display.tint.opacity(colorScheme == .dark ? 0.18 : 0.11), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(display.tint.opacity(colorScheme == .dark ? 0.26 : 0.18), lineWidth: 0.8)
            }
    }

    private func pickupInviteStatusDisplay(_ status: String) -> (title: String, tint: Color) {
        switch status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "pending":
            return ("Pending invite", FGColor.secondaryText(colorScheme))
        case "accepted":
            return ("Accepted", FGColor.accentGreen)
        case "maybe":
            return ("Maybe", Color.orange)
        case "declined":
            return ("Declined", colorScheme == .dark ? Color.red.opacity(0.74) : Color.red.opacity(0.68))
        default:
            return ("Already invited", Color.orange)
        }
    }

    private func scheduleFanSearch(_ raw: String) {
        searchTask?.cancel()
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            isSearching = false
            searchResults = []
            return
        }
        isSearching = true
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            let results = await viewModel.searchPickupInvitableFans(query: trimmed, limit: 20)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                searchResults = results
                isSearching = false
            }
        }
    }

    private func sendInvites() async {
        guard canSend else { return }
        isSending = true
        errorText = nil
        defer { isSending = false }

        let results = await viewModel.createPickupGameInvites(
            game: game,
            inviteeUserIds: Array(selectedFriendIds),
            message: nil
        )
        let created = results.filter { $0.outcome == "created" }.count
        let duplicates = results.filter { $0.outcome == "duplicate" }.count
#if DEBUG
        print("[PickupInviteDebug] duplicateSkipped=\(duplicates)")
#endif
        if created > 0 || duplicates > 0 {
            dismiss()
        } else {
            errorText = "No invites were sent. Try again."
        }
    }
}

/// Skill + optional message before creating `pickup_game_requests`.
struct PickupGameJoinRequestComposerSheet: View {
    @ObservedObject var viewModel: MapViewModel
    let pickupGame: PickupGameRow
    var onFinished: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var skill: PickupGameSkillLevel = .casual
    @State private var message: String = ""
    @State private var isSubmitting = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Your skill level for this game") {
                    Picker("Skill", selection: $skill) {
                        ForEach(PickupGameSkillLevel.allCases) { level in
                            Text(level.displayTitle).tag(level)
                        }
                    }
                    .pickerStyle(.inline)
                }
                Section("Safety") {
                    HStack(alignment: .top, spacing: FGSpacing.sm) {
                        Image(systemName: "exclamationmark.shield.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(FGColor.accentYellow)
                            .padding(.top, 1)
                        Text("Pickup games and meetups involve physical activity and real-world interaction. Participate at your own risk and use good judgment.")
                            .font(FGTypography.caption)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Section("Optional message") {
                    TextField("Short intro (optional)", text: $message, axis: .vertical)
                        .lineLimit(3...6)
                }
                if let errorText, !errorText.isEmpty {
                    Section {
                        Text(errorText)
                            .font(FGTypography.caption)
                            .foregroundStyle(FGColor.dangerRed)
                    }
                }
            }
            .navigationTitle("Request to join")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        onFinished()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        Task { await submit() }
                    }
                    .disabled(isSubmitting || !viewModel.canJoinPickupGames)
                }
            }
        }
    }

    private func submit() async {
        guard viewModel.canJoinPickupGames else {
            viewModel.logBusinessUserGateBlocked(action: "joinPickupGame")
            errorText = BusinessFanGateCopy.pickupFanOnly
            return
        }
        isSubmitting = true
        errorText = nil
        defer { isSubmitting = false }
        do {
            try await viewModel.createPickupJoinRequest(
                pickupGameId: pickupGame.id,
                requesterSkillLevel: skill.rawValue,
                message: message
            )
            onFinished()
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

/// Settings → My pickup games → manage join requests for one game.
struct PickupOrganizerRequestsSheet: View {
    @ObservedObject var viewModel: MapViewModel
    let game: PickupGameRow

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dismiss) private var dismiss

    @State private var rows: [PickupGameRequestRow] = []
    @State private var loadError: String?
    @State private var busyRequestId: UUID?

    private var useCompactRequestCopy: Bool {
        horizontalSizeClass == .compact
    }

    private var pendingRows: [PickupGameRequestRow] {
        rows.filter { $0.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "pending" }
            .sorted { $0.pickupJoinRequestRecencyInstant > $1.pickupJoinRequestRecencyInstant }
    }

    private var approvedRows: [PickupGameRequestRow] {
        rows.filter { $0.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "approved" }
            .sorted { $0.pickupJoinRequestRecencyInstant > $1.pickupJoinRequestRecencyInstant }
    }

    private var rejectedRows: [PickupGameRequestRow] {
        rows.filter { $0.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "rejected" }
            .sorted { $0.pickupJoinRequestRecencyInstant > $1.pickupJoinRequestRecencyInstant }
    }

    private var withdrawnRows: [PickupGameRequestRow] {
        rows.filter {
            let s = $0.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return s == "cancelled" || s == "withdrawn"
        }
        .sorted { $0.pickupJoinRequestRecencyInstant > $1.pickupJoinRequestRecencyInstant }
    }

    var body: some View {
        NavigationStack {
            List {
                if let loadError, !loadError.isEmpty {
                    Text(loadError)
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.dangerRed)
                        .listRowBackground(Color.clear)
                }
                if rows.isEmpty && loadError == nil {
                    Text("No requests yet.")
                        .font(FGTypography.body)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .listRowBackground(Color.clear)
                }
                if !pendingRows.isEmpty {
                    Section {
                        ForEach(pendingRows) { req in
                            organizerRequestCard(req)
                                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }
                    } header: {
                        Text("Pending")
                            .textCase(nil)
                    }
                }
                if !approvedRows.isEmpty {
                    Section {
                        ForEach(approvedRows) { req in
                            organizerRequestCard(req)
                                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }
                    } header: {
                        Text("Approved")
                            .textCase(nil)
                    }
                }
                if !rejectedRows.isEmpty {
                    Section {
                        ForEach(rejectedRows) { req in
                            organizerRequestCard(req)
                                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }
                    } header: {
                        Text("Rejected")
                            .textCase(nil)
                    }
                }
                if !withdrawnRows.isEmpty {
                    Section {
                        ForEach(withdrawnRows) { req in
                            organizerRequestCard(req)
                                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }
                    } header: {
                        Text("Can’t make it")
                            .textCase(nil)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .fanGeoScreenBackground()
            .navigationTitle("Requests")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await reload() }
            .onChange(of: viewModel.pickupOrganizerRequestsSyncGeneration) { _, _ in
                Task { await reload() }
            }
            .onAppear {
                PickupGameStartedStateDebug.log(
                    row: game,
                    now: Date(),
                    allowedActions: "approve,reject,remove_players"
                )
            }
        }
    }

    @ViewBuilder
    private func pickupJoinRequestStatusPill(_ status: String) -> some View {
        switch status.lowercased() {
        case "pending":
            FGStatusPill(title: "Pending", kind: .custom(tint: Color.orange))
        case "approved":
            FGStatusPill(title: "Approved", kind: .approved)
        case "rejected":
            FGStatusPill(title: "Rejected", kind: .rejected)
        case "cancelled":
            FGStatusPill(title: "Withdrawn", kind: .custom(tint: FGColor.mutedText(colorScheme)))
        case "withdrawn":
            FGStatusPill(title: "Withdrawn", kind: .custom(tint: FGColor.mutedText(colorScheme)))
        default:
            FGStatusPill(title: status.capitalized, kind: .custom(tint: FGColor.mutedText(colorScheme)))
        }
    }

    @ViewBuilder
    private func organizerRequestCard(_ req: PickupGameRequestRow) -> some View {
        let profile = viewModel.pickupJoinRequesterProfileByUserId[req.requester_user_id]
        let profileName = profile?.display_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let displayName = profileName.isEmpty ? req.requesterNameForUI : profileName
        let emailLine = (profile?.email ?? req.requester_email ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let thumbRaw = ImageDisplayURL.canonicalStorageURLString(profile?.avatar_thumbnail_url)
        let fullRaw = ImageDisplayURL.canonicalStorageURLString(profile?.avatar_url)
        let thumb: String? = thumbRaw.isEmpty ? nil : thumbRaw
        let full = fullRaw.isEmpty ? "" : fullRaw
        let token = viewModel.pickupJoinRequesterAvatarTokenByUserId[req.requester_user_id] ?? UUID()
        let isPending = req.status.lowercased() == "pending"
        let isTerminal = !isPending

        VStack(alignment: .leading, spacing: FGSpacing.md) {
            HStack(alignment: .top, spacing: FGSpacing.md) {
                PublicProfileAvatarTap(
                    userId: req.requester_user_id,
                    context: "pickup_join_request",
                    activeSheet: "manage_requests"
                ) {
                    UserAvatarView(
                        avatarThumbnailURL: thumb,
                        avatarURL: full,
                        avatarDisplayRefreshToken: token,
                        displayName: displayName,
                        email: emailLine,
                        size: 56,
                        fallbackStyle: colorScheme == .dark ? .darkCardTranslucent : .lightOnWhiteChrome,
                        imagePlaceholderTint: colorScheme == .dark ? .white.opacity(0.75) : nil
                    )
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: FGSpacing.sm) {
                        Text(displayName)
                            .font(FGTypography.cardTitle)
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        pickupJoinRequestStatusPill(req.status)
                    }

                    Text(req.organizerRequestedCaption(compactWidth: useCompactRequestCopy))
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))

                    Text(req.organizerDecisionStatusCaption(compactWidth: useCompactRequestCopy))
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(isTerminal ? FGColor.secondaryText(colorScheme) : Color.orange.opacity(colorScheme == .dark ? 0.95 : 0.88))

                    Text(req.requesterSkillLevelEnum.displayTitle)
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))

                    if let m = req.message?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty {
                        Text(m)
                            .font(FGTypography.body)
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .padding(FGSpacing.sm + 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(FGColor.cardBackground(colorScheme).opacity(colorScheme == .dark ? 0.45 : 0.55))
                            .clipShape(RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
                    }
                }
            }

            if isPending {
                HStack(spacing: FGSpacing.sm) {
                    Button {
                        Task { await decide(req, approve: true) }
                    } label: {
                        if busyRequestId == req.id {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Approve")
                                .font(FGTypography.metadata.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(FGColor.accentGreen)
                    .disabled(busyRequestId != nil)

                    Button(role: .destructive) {
                        Task { await decide(req, approve: false) }
                    } label: {
                        Text("Reject")
                            .font(FGTypography.metadata.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(busyRequestId != nil)
                }
            }
        }
        .padding(FGSpacing.lg)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(FGColor.divider(colorScheme).opacity(colorScheme == .dark ? 0.55 : 0.4), lineWidth: 1)
            }
        }
        .opacity(isTerminal ? 0.92 : 1)
        .accessibilityElement(children: .combine)
    }

    private func reload() async {
        loadError = nil
        do {
            let next = try await viewModel.fetchOrganizerPickupRequests(pickupGameId: game.id)
            rows = next
            await viewModel.loadPickupJoinRequesterProfilesForOrganizerSheet(
                requesterIds: Set(next.map(\.requester_user_id))
            )
        } catch {
            loadError = error.localizedDescription
            rows = []
        }
        await viewModel.loadPendingPickupGameJoinRequestCountForCreator(resyncRealtimeSubscription: false)
    }

    private func decide(_ req: PickupGameRequestRow, approve: Bool) async {
        busyRequestId = req.id
        loadError = nil
        defer { busyRequestId = nil }
        do {
            if approve {
                try await viewModel.approvePickupJoinRequest(requestId: req.id, pickupGameId: game.id)
            } else {
                try await viewModel.rejectPickupJoinRequest(requestId: req.id, pickupGameId: game.id)
            }
            await reload()
            await viewModel.loadMyPickupGamesForSettings()
        } catch {
            loadError = error.localizedDescription
        }
    }
}
