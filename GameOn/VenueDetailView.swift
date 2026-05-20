import SwiftUI

struct VenueDetailView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @State private var showClaimConfirmation = false
    @State private var claimActionError: String?
    @State private var predictionClosedMessage: String?
    @State private var contentRevealPhase = 1
    @State private var predictionSheet: VenueDetailPredictionSheetContext?

    let bar: BarVenue
    let selectedEvent: SportsEvent?
    let isFavorite: Bool
    let goingCount: Int
    var liveEnergy: FanGeoLiveEnergy? = nil
    var livePresenceViewerUserID: UUID? = nil
    let iconForSport: (String) -> String
    /// When nil, no rating card is shown.
    var mergedRating: Double? = nil
    var ratingCount: Int = 0
    var displaySport: String? = nil
    var sportsSupported: [String] = []
    var hasGamesScheduledToday: Bool = true
    var venueEventRows: [VenueEventRow] = []
    var venuePredictionSummaries: [UUID: VenueEventPredictionSummary] = [:]
    var isBusinessConfirmed: Bool = false
    let onDirections: () -> Void
    let onCall: () -> Void
    let onFavorite: () -> Void
    var onAddressTap: (() -> Void)? = nil
    var onRateVenue: (() -> Void)? = nil
    let experience: VenueExperience?
    var coverPhotoURL: String? = nil
    var menuPhotoURL: String? = nil
    /// Discover “Claim this business” → venue owner flow (optional so other call sites compile).
    var onClaimThisBusiness: ((BarVenue) async -> String?)? = nil
    var showsBusinessOwnershipSection: Bool = false
    /// Current claim-review lifecycle for the signed-in venue owner on this venue.
    var businessClaimStatus: VenueOwnershipClaimStatus = .unclaimed
    /// When false, fan-only controls (save, rate) are shown disabled and route taps through ``onFanFeatureBlocked``.
    var showsFanOnlyActionButtons: Bool = true
    var onFanFeatureBlocked: ((String) -> Void)? = nil
    /// Guest Discover: hide scheduled game details and show ``DiscoverGuestGameLockCard`` instead.
    var locksScheduledGameDetailsForGuest: Bool = false
    /// Guest Discover: same fan auth presentation as other Discover CTAs.
    var onGuestGameLoginCTA: (() -> Void)? = nil
    var onLoadVenuePredictionSummaries: (([UUID]) async -> Void)? = nil
    var onRefreshVenuePredictionSummary: ((UUID) async -> Void)? = nil
    /// Fan Home Crowd quick toggle (venue hero).
    var showsHomeCrowdControls: Bool = false
    var isHomeCrowdVenue: Bool = false
    var onToggleHomeCrowd: (() async -> Void)? = nil

    @State private var isHomeCrowdActionInFlight = false

    private static let sqlDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    private func runFanOnlyAction(_ debugAction: String, _ handler: () -> Void) {
        if showsFanOnlyActionButtons {
            handler()
        } else {
            onFanFeatureBlocked?(debugAction)
        }
    }

    private var resolvedRating: Double? {
        guard ratingCount > 0 else { return nil }
        return mergedRating
    }

    private var hasDisplaySport: Bool {
        guard let displaySport else { return false }
        return !displaySport.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var ratingSubtitle: String {
        ratingCount == 1 ? "1 rating" : "\(ratingCount) ratings"
    }

    private var heroFallbackIconName: String {
        hasDisplaySport ? iconForSport(displaySport ?? "") : "building.2.fill"
    }

    private var heroImageURL: URL? {
        guard let raw = venueDetailsHeroURLString,
              let url = URL(string: raw) else {
            return nil
        }
        return url
    }

    private var venueDetailsHeroURLString: String? {
        ImageDisplayURL.forDetail(
            thumbnail: bar.coverPhotoThumbnailURL,
            full: coverPhotoURL ?? bar.coverPhotoURL
        ) ?? ImageDisplayURL.forDetail(
            thumbnail: bar.menuPhotoThumbnailURL,
            full: menuPhotoURL ?? bar.menuPhotoURL
        )
    }

    private var venueDetailsHeroUsesThumbnail: Bool {
        let selected = venueDetailsHeroURLString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let coverThumb = bar.coverPhotoThumbnailURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let menuThumb = bar.menuPhotoThumbnailURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !selected.isEmpty && (selected == coverThumb || selected == menuThumb)
    }

    private var insideVenueImageURL: URL? {
        guard let raw = venueDetailsSecondPhotoURLString,
              let url = URL(string: raw) else {
            return nil
        }
        return url
    }

    private var venueDetailsSecondPhotoURLString: String? {
        guard let second = ImageDisplayURL.forDetail(
            thumbnail: bar.menuPhotoThumbnailURL,
            full: menuPhotoURL ?? bar.menuPhotoURL
        ) else { return nil }
        return second == venueDetailsHeroURLString ? nil : second
    }

    private var venueShareText: String {
        var lines = [bar.name, bar.address]
        if !locksScheduledGameDetailsForGuest, let selectedEvent {
            lines.append("Catch \(selectedEvent.title) on \(selectedEvent.date.formatted(date: .abbreviated, time: .omitted)) at \(selectedEvent.time)")
        }
        lines.append("Shared from FanGeo")
        return lines.joined(separator: "\n")
    }

    /// Same resolution as ``VenueGameBusinessEmail`` (`venues.owner_email` with optional active-business fallback, non-archived, strict-valid).
    private var venueBusinessContactEmail: String? {
        VenueGameBusinessEmail.resolvedDisplayEmail(for: bar)
    }

    private var quickActionsSectionSubtitle: String {
        venueBusinessContactEmail != nil
            ? "Get there, call, email, save, or share this venue"
            : "Get there, call, save, or share this venue"
    }

    private func openVenueBusinessMail() {
        guard let email = venueBusinessContactEmail, let url = VenueGameBusinessEmail.mailtoURL(for: email) else { return }
        VenueEmailActionDebug.log(bar: bar, emailActionVisible: true, openedMailto: url.absoluteString, businessClaimStatus: businessClaimStatus)
        openURL(url)
    }

    private var venueFeatureItems: [VenueFeatureDisplayItem] {
        venueFeaturesForDisplay(bar)
    }

    private func logVenueFeaturesDebug(renderedItems: [VenueFeatureDisplayItem]) {
#if DEBUG
        let enabledLabels = renderedItems
            .filter { $0.availability == .available }
            .map(\.label)
            .joined(separator: " | ")
        let disabledLabels = renderedItems
            .filter { $0.availability == .unavailable }
            .map(\.label)
            .joined(separator: " | ")
        let unknownLabels = renderedItems
            .filter { $0.availability == .unknown }
            .map(\.label)
            .joined(separator: " | ")
        print("[VenueFeaturesDebug] venueId=\(bar.id.uuidString)")
        print("[VenueFeaturesDebug] sourceFeatureCount=\(VenueFeatureDisplaySource.configuredFeatureCount(for: bar))")
        print("[VenueFeaturesDebug] enabledFeatures=\(enabledLabels)")
        print("[VenueFeaturesDebug] disabledFeatures=\(disabledLabels)")
        print("[VenueFeaturesDebug] unknownFeatures=\(unknownLabels)")
        print("[VenueFeaturesDebug] renderedFeatureLabels=\(renderedItems.map(\.label).joined(separator: " | "))")
#endif
    }

    private var businessClaimTint: Color {
        switch businessClaimStatus {
        case .unclaimed:
            return FGColor.accentBlue
        case .pendingReview:
            return FGColor.accentYellow
        case .approved:
            return FGColor.accentGreen
        case .alreadyClaimedByOtherBusiness:
            return FGColor.mutedText(colorScheme)
        case .rejected:
            return FGColor.dangerRed
        }
    }

    private var businessClaimStatusPillTitle: String {
        switch businessClaimStatus {
        case .unclaimed:
            return "Unclaimed"
        case .pendingReview:
            return "Under review"
        case .approved:
            return "Verified"
        case .alreadyClaimedByOtherBusiness:
            return "Already claimed"
        case .rejected:
            return "Needs review"
        }
    }

    private var businessClaimStatusIcon: String {
        switch businessClaimStatus {
        case .unclaimed:
            return "building.2.crop.circle"
        case .pendingReview:
            return "clock.badge.exclamationmark"
        case .approved:
            return "checkmark.seal.fill"
        case .alreadyClaimedByOtherBusiness:
            return "building.2.crop.circle.badge.checkmark"
        case .rejected:
            return "exclamationmark.triangle.fill"
        }
    }

    private var businessClaimHeadline: String {
        switch businessClaimStatus {
        case .unclaimed:
            return "Claim this business"
        case .pendingReview:
            return "Claim under review"
        case .approved:
            return "Managed by verified business"
        case .alreadyClaimedByOtherBusiness:
            return "Already claimed"
        case .rejected:
            return "Claim requires additional review"
        }
    }

    private var businessClaimSubtitle: String {
        switch businessClaimStatus {
        case .unclaimed:
            return "Claim requests are reviewed before owner tools are enabled."
        case .pendingReview:
            return "Your ownership request is pending FanGeo review."
        case .approved:
            return "This venue is linked to your verified business account."
        case .alreadyClaimedByOtherBusiness:
            return "This venue is already managed by another verified business."
        case .rejected:
            return "Your previous request needs more review. You can resubmit with updated business details."
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FGSpacing.lg) {
                venueHeroSection
                insideVenueSection
                    .progressiveAppear(isVisible: contentRevealPhase >= 2)
                venueFeaturesSection
                    .progressiveAppear(isVisible: contentRevealPhase >= 2)
                venueActionSection
                    .progressiveAppear(isVisible: contentRevealPhase >= 3)
                if locksScheduledGameDetailsForGuest {
                    DiscoverGuestGameLockCard {
                        onGuestGameLoginCTA?()
                    }
                    .progressiveAppear(isVisible: contentRevealPhase >= 3)
                }
                venueBusinessClaimSection
                    .progressiveAppear(isVisible: contentRevealPhase >= 3)
                if !locksScheduledGameDetailsForGuest {
                    venueGamesSection
                        .progressiveAppear(isVisible: contentRevealPhase >= 3)
                }
                venueTagsSection
                    .progressiveAppear(isVisible: contentRevealPhase >= 4)
            }
            .frame(maxWidth: 680, alignment: .top)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.horizontal, 22)
            .padding(.top, FGSpacing.lg)
            .padding(.bottom, 132)
        }
        .scrollIndicators(.hidden)
        .fanGeoScreenBackground()
        .task(id: bar.id) {
            await revealVenueDetailContent()
            VenueEmailActionDebug.logLoad(bar: bar, businessClaimStatus: businessClaimStatus)
            VenueGameBusinessEmail.logDebug(bar: bar)
        }
        .onAppear(perform: logVenueDetailDebugState)
        .sheet(item: $predictionSheet) { context in
            VenueEventPredictionSheet(
                venueEventID: context.venueEventID,
                teams: context.teams,
                predictionType: context.predictionType,
                onSaved: {
                    await onRefreshVenuePredictionSummary?(context.venueEventID)
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .alert("Claim this venue?", isPresented: $showClaimConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Submit for Review") {
                Task {
                    if let onClaimThisBusiness,
                       let error = await onClaimThisBusiness(bar) {
                        claimActionError = error
                    }
                }
            }
        } message: {
            Text("FanGeo will review your ownership request before enabling venue tools for this location.")
        }
        .alert(
            "Couldn’t submit claim",
            isPresented: Binding(
                get: { claimActionError != nil },
                set: { if !$0 { claimActionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                claimActionError = nil
            }
        } message: {
            Text(claimActionError ?? "")
        }
        .alert(
            "FanGeo",
            isPresented: Binding(
                get: { predictionClosedMessage != nil },
                set: { if !$0 { predictionClosedMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                predictionClosedMessage = nil
            }
        } message: {
            Text(predictionClosedMessage ?? "")
        }
    }

    @MainActor
    private func revealVenueDetailContent() async {
        contentRevealPhase = 1
        await Task.yield()
        guard !Task.isCancelled else { return }

        withAnimation(.easeOut(duration: 0.22)) {
            contentRevealPhase = 2
        }

        try? await Task.sleep(nanoseconds: 55_000_000)
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.24)) {
            contentRevealPhase = 3
        }

        try? await Task.sleep(nanoseconds: 65_000_000)
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.24)) {
            contentRevealPhase = 4
        }
    }

    private var venueHeroSection: some View {
        ZStack(alignment: .topTrailing) {
            heroBackground

            LinearGradient(
                colors: [Color.black.opacity(0.04), Color.black.opacity(0.72)],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: FGSpacing.sm) {
                HStack(alignment: .top, spacing: FGSpacing.md) {
                    if isBusinessConfirmed {
                        compactHeroBadge("Confirmed Venue", tint: FGColor.accentGreen)
                        .progressiveAppear(isVisible: contentRevealPhase >= 2, yOffset: 4)
                    }

                    Spacer(minLength: FGSpacing.md)

                    HStack(spacing: 10) {
                        if showsHomeCrowdControls {
                            homeCrowdHeroToggleButton
                                .progressiveAppear(isVisible: contentRevealPhase >= 2, yOffset: 4)
                        }

                        Button {
                            runFanOnlyAction("favoriteVenue", onFavorite)
                        } label: {
                            Image(systemName: isFavorite ? "heart.fill" : "heart")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(isFavorite ? Color.red : Color.white)
                                .frame(width: 44, height: 44)
                                .background(Color.black.opacity(0.25))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .opacity(showsFanOnlyActionButtons ? 1 : 0.5)
                        .progressiveAppear(isVisible: contentRevealPhase >= 2, yOffset: 4)
                    }
                }

                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: FGSpacing.xs) {
                    Text(bar.name)
                        .font(FGTypography.heroTitle)
                        .foregroundStyle(.white)
                        .lineLimit(2)

                    if !bar.distance.isEmpty {
                        FGStatusPill(title: bar.distance, kind: .custom(tint: FGColor.accentYellow))
                    }
                }
                .progressiveAppear(isVisible: contentRevealPhase >= 2, yOffset: 6)
            }
            .padding(FGSpacing.lg)
        }
        .frame(height: 248)
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.sheet, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FGRadius.sheet, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        }
        .floatingShadow()
    }

    @ViewBuilder
    private var heroBackground: some View {
        if let heroImageURL {
            DiscoverCachedRemoteImage(url: heroImageURL, contentMode: .fill) {
                heroFallback
            }
        } else {
            heroFallback
        }
    }

    private var heroFallback: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.black.opacity(0.94),
                    FGColor.gradientMiddle.opacity(0.74),
                    FGColor.gradientEnd.opacity(0.84)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(Color.white.opacity(0.10))
                .frame(width: 190, height: 190)
                .blur(radius: 26)
                .offset(x: 112, y: -74)

            Circle()
                .fill(FGColor.accentBlue.opacity(0.16))
                .frame(width: 168, height: 168)
                .blur(radius: 20)
                .offset(x: -118, y: 76)
        }
    }

    @ViewBuilder
    private var insideVenueSection: some View {
        if let insideVenueImageURL {
            VStack(alignment: .leading, spacing: FGSpacing.sm) {
                FGSectionHeader(
                    "Inside the venue",
                    subtitle: "Menu, drinks, crowd, patio, and atmosphere"
                )

                ZStack(alignment: .bottomLeading) {
                    DiscoverCachedRemoteImage(url: insideVenueImageURL, contentMode: .fill) {
                        LinearGradient(
                            colors: [FGColor.gradientStart.opacity(0.70), FGColor.gradientEnd.opacity(0.90)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    }

                    LinearGradient(
                        colors: [Color.black.opacity(0.02), Color.black.opacity(0.58)],
                        startPoint: .top,
                        endPoint: .bottom
                    )

                    Text("A look at the vibe before you go")
                        .font(FGTypography.cardTitle)
                        .foregroundStyle(.white)
                        .padding(FGSpacing.lg)
                }
                .frame(height: 172)
                .clipShape(RoundedRectangle(cornerRadius: FGRadius.sheet, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: FGRadius.sheet, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                }
                .floatingShadow()
            }
        }
    }

    private var venueStatsSection: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 128), spacing: FGSpacing.md)],
            spacing: FGSpacing.md
        ) {
            statCard(
                title: bar.distance.isEmpty ? "Venue" : bar.distance,
                subtitle: "Distance",
                icon: "location.fill",
                tint: FGColor.accentBlue
            )
            if let rating = resolvedRating, let onRateVenue {
                Button {
                    runFanOnlyAction("rateVenue", onRateVenue)
                } label: {
                    statCard(
                        title: String(format: "%.1f", rating),
                        subtitle: ratingSubtitle,
                        icon: "star.fill",
                        tint: FGColor.accentYellow
                    )
                }
                .buttonStyle(.plain)
                .opacity(showsFanOnlyActionButtons ? 1 : 0.55)
            } else if let rating = resolvedRating {
                statCard(
                    title: String(format: "%.1f", rating),
                    subtitle: ratingSubtitle,
                    icon: "star.fill",
                    tint: FGColor.accentYellow
                )
            }
        }
    }

    private func statCard(title: String, subtitle: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: FGSpacing.xs + 2) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(FGTypography.cardTitle)
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            Text(subtitle)
                .font(FGTypography.caption)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
        }
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
        .padding(FGSpacing.md)
        .background(FGColor.cardBackground(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FGRadius.card, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
        }
        .softCardShadow()
    }

    private var homeCrowdHeroToggleButton: some View {
        Button {
            runFanOnlyAction("toggleHomeCrowd") {
                Task { await runHomeCrowdToggle() }
            }
        } label: {
            HomeCrowdShieldStarBadge(
                diameter: 44,
                visualState: isHomeCrowdVenue ? .active : .inactive
            )
            .overlay {
                Circle()
                    .strokeBorder(
                        isHomeCrowdVenue
                            ? Color(red: 0.72, green: 0.48, blue: 1.0).opacity(0.85)
                            : Color.white.opacity(0.28),
                        lineWidth: isHomeCrowdVenue ? 2 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .opacity(showsFanOnlyActionButtons ? 1 : 0.5)
        .disabled(isHomeCrowdActionInFlight)
        .accessibilityLabel(isHomeCrowdVenue ? "Remove this Home Crowd" : "Make this my Home Crowd")
    }

    @MainActor
    private func runHomeCrowdToggle() async {
        guard !isHomeCrowdActionInFlight else { return }
        isHomeCrowdActionInFlight = true
        defer { isHomeCrowdActionInFlight = false }
        await onToggleHomeCrowd?()
    }

    private var venueActionSection: some View {
        FGCard {
            FGSectionHeader("Quick actions", subtitle: quickActionsSectionSubtitle)

            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: 108, maximum: 150), spacing: FGSpacing.sm, alignment: .top)
                ],
                spacing: FGSpacing.sm
            ) {
                Button(action: onDirections) {
                    actionCardContent(
                        title: "Directions",
                        subtitle: "Open maps",
                        icon: "map.fill",
                        tint: FGColor.accentBlue
                    )
                }
                .buttonStyle(.plain)

                Button(action: onCall) {
                    actionCardContent(
                        title: "Call",
                        subtitle: "Contact venue",
                        icon: "phone.fill",
                        tint: FGColor.businessGreen
                    )
                }
                .buttonStyle(.plain)

                if venueBusinessContactEmail != nil {
                    Button(action: openVenueBusinessMail) {
                        actionCardContent(
                            title: "Email",
                            subtitle: "Email venue",
                            icon: "envelope.fill",
                            tint: FGColor.gradientMiddle
                        )
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    runFanOnlyAction("favoriteVenue", onFavorite)
                } label: {
                    actionCardContent(
                        title: isFavorite ? "Saved" : "Save",
                        subtitle: isFavorite ? "In favorites" : "Pin this venue",
                        icon: isFavorite ? "heart.fill" : "heart",
                        tint: Color.red
                    )
                }
                .buttonStyle(.plain)
                .opacity(showsFanOnlyActionButtons ? 1 : 0.55)

                ShareLink(item: venueShareText) {
                    actionCardContent(
                        title: "Share",
                        subtitle: "Send venue",
                        icon: "square.and.arrow.up",
                        tint: FGColor.accentYellow
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func actionCardContent(title: String, subtitle: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .font(.callout.weight(.semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(FGTypography.body.weight(.semibold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
            Text(subtitle)
                .font(FGTypography.caption)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, FGSpacing.sm + 2)
        .background(FGColor.background(colorScheme).opacity(colorScheme == .dark ? 0.50 : 0.86))
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous)
                .strokeBorder(tint.opacity(colorScheme == .dark ? 0.30 : 0.18), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var venueBusinessClaimSection: some View {
        if showsBusinessOwnershipSection {
            FGCard {
                FGSectionHeader(
                    "Business ownership",
                    subtitle: "Venue ownership requests stay in review until FanGeo verifies the business connection."
                ) {
                    FGStatusPill(
                        title: businessClaimStatusPillTitle,
                        kind: .custom(tint: businessClaimTint)
                    )
                }

                HStack(alignment: .top, spacing: FGSpacing.md) {
                    Image(systemName: businessClaimStatusIcon)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(businessClaimTint)

                    VStack(alignment: .leading, spacing: FGSpacing.xs) {
                        Text(businessClaimHeadline)
                            .font(FGTypography.cardTitle)
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                        Text(businessClaimSubtitle)
                            .font(FGTypography.caption)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    }

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(FGSpacing.lg)
                .background(businessClaimTint.opacity(colorScheme == .dark ? 0.12 : 0.08))
                .clipShape(RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous))

                if onClaimThisBusiness != nil {
                    switch businessClaimStatus {
                    case .unclaimed:
                        FGSecondaryButton(title: "Claim this business", systemImage: "building.2.crop.circle") {
                            showClaimConfirmation = true
                        }
                    case .pendingReview:
                        FGSecondaryButton(title: "Claim under review", systemImage: "clock.badge.exclamationmark") {}
                            .disabled(true)
                            .opacity(0.72)
                    case .approved:
                        EmptyView()
                    case .alreadyClaimedByOtherBusiness:
                        EmptyView()
                    case .rejected:
                        FGSecondaryButton(title: "Resubmit claim", systemImage: "arrow.clockwise.circle") {
                            showClaimConfirmation = true
                        }
                    }
                }
            }
        }
    }

    private var venueGamesSection: some View {
        let games = upcomingVenueGameItems

        return FGCard {
            FGSectionHeader(
                "Games showing",
                subtitle: "Today and upcoming"
            )

            if games.isEmpty {
                FGEmptyState(
                    title: "No upcoming games listed yet.",
                    subtitle: "",
                    systemImage: "tv"
                )
            } else {
                VStack(spacing: FGSpacing.sm) {
                    ForEach(games) { game in
                        gameRow(game)
                    }
                }
            }
        }
        .task(id: predictionLoadToken(for: games)) {
            let ids = games.compactMap { game -> UUID? in
                guard game.supportsPredictions else { return nil }
                return game.venueEventID
            }
            await onLoadVenuePredictionSummaries?(ids)
        }
    }

    private var upcomingVenueGameItems: [VenueDetailGameItem] {
        let now = Date()
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)
        var seenKeys = Set<String>()

        var items = venueEventRows.compactMap { row -> VenueDetailGameItem? in
            guard venueEventRowMatchesCurrentVenue(row) else { return nil }
            guard venueEventRowIsActive(row) else { return nil }
            guard venueEventRowIsTodayOrUpcoming(row, now: now, todayStart: todayStart, calendar: calendar) else { return nil }
            guard let title = trimmedNonEmpty(row.event_title) else { return nil }

            let sport = trimmedNonEmpty(row.sport) ?? displaySport ?? bar.primarySport
            let start = venueEventScheduledStart(row)
            let day = venueEventDay(row)
            let key = row.id?.uuidString ?? "\(title)|\(row.event_date ?? "")|\(row.event_time ?? "")"
            guard seenKeys.insert(key).inserted else { return nil }

            return VenueDetailGameItem(
                id: key,
                venueEventID: row.id,
                title: title,
                sport: sport,
                teams: predictionTeams(for: row),
                dateTimeText: venueGameDateTimeText(start: start, day: day, timeText: row.event_time),
                sortDate: start ?? day ?? Date.distantFuture,
                startsAt: start,
                status: venueGameStatus(start: start, now: now)
            )
        }

        if let selectedEvent,
           calendar.startOfDay(for: selectedEvent.date) >= todayStart,
           bar.games.contains(where: { $0.caseInsensitiveCompare(selectedEvent.title) == .orderedSame }) {
            let key = "selected|\(selectedEvent.title)|\(selectedEvent.date.timeIntervalSince1970)"
            let alreadyListed = items.contains {
                $0.title.caseInsensitiveCompare(selectedEvent.title) == .orderedSame &&
                    calendar.isDate($0.sortDate, inSameDayAs: selectedEvent.date)
            }
            if !alreadyListed, seenKeys.insert(key).inserted {
                items.append(
                    VenueDetailGameItem(
                        id: key,
                        venueEventID: nil,
                        title: selectedEvent.title,
                        sport: selectedEvent.sport,
                        teams: nil,
                        dateTimeText: "\(selectedEvent.date.formatted(date: .abbreviated, time: .omitted)) at \(selectedEvent.time)",
                        sortDate: selectedEvent.date,
                        startsAt: selectedEvent.date,
                        status: .confirmed
                    )
                )
            }
        }

        return items.sorted {
            if $0.sortDate != $1.sortDate { return $0.sortDate < $1.sortDate }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    private func gameRow(_ game: VenueDetailGameItem) -> some View {
        VStack(alignment: .leading, spacing: FGSpacing.sm) {
            HStack(alignment: .top, spacing: FGSpacing.md) {
                Image(systemName: iconForSport(game.sport))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(FGColor.accentBlue)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: FGSpacing.xs) {
                    Text(game.title)
                        .font(FGTypography.body.weight(.semibold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(2)

                    Text(game.dateTimeText)
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }

                Spacer(minLength: FGSpacing.sm)

                if let status = game.status {
                    FGStatusPill(title: status.title, kind: .custom(tint: status.tint))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }

            if game.supportsPredictions, let eventID = game.venueEventID, let teams = game.teams {
                VenueEventPredictionModule(
                    venueEventID: eventID,
                    teams: teams,
                    summary: venuePredictionSummaries[eventID],
                    isLocked: game.predictionsLocked,
                    onOpen: { type in
                        openPredictionSheet(eventID: eventID, teams: teams, type: type, isLocked: game.predictionsLocked)
                    },
                    onLockedTap: {
                        predictionClosedMessage = "Predictions closed for this game."
                    }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(FGSpacing.md)
        .background(FGColor.background(colorScheme).opacity(colorScheme == .dark ? 0.60 : 0.92))
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
        }
    }

    private func venueEventRowMatchesCurrentVenue(_ row: VenueEventRow) -> Bool {
        if row.venue_id == bar.id { return true }

        if let venueName = trimmedNonEmpty(row.venue_name),
           venueName.caseInsensitiveCompare(bar.name) == .orderedSame {
            return true
        }

        if let rowOwner = trimmedNonEmpty(row.owner_email),
           let barOwner = bar.ownerEmail,
           OwnerBusinessEmail.normalized(rowOwner) == OwnerBusinessEmail.normalized(barOwner) {
            return true
        }

        return false
    }

    private func venueEventRowIsActive(_ row: VenueEventRow) -> Bool {
        let status = row.admin_status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return status == nil || status?.isEmpty == true || status == "active"
    }

    private func venueEventRowIsTodayOrUpcoming(
        _ row: VenueEventRow,
        now: Date,
        todayStart: Date,
        calendar: Calendar
    ) -> Bool {
        if let start = venueEventScheduledStart(row) {
            let liveEnd = start.addingTimeInterval(TimeInterval(FanGeoLiveEnergyTiming.liveWindowHours * 3600))
            return start >= now || (now >= start && now <= liveEnd)
        }

        guard let day = venueEventDay(row) else { return false }
        return calendar.startOfDay(for: day) >= todayStart
    }

    private func venueEventScheduledStart(_ row: VenueEventRow) -> Date? {
        if let start = FanGeoLiveEnergyTiming.parseScheduledStart(row.scheduled_start_at) {
            return start
        }

        guard let day = venueEventDay(row) else { return nil }
        guard let time = trimmedNonEmpty(row.event_time), time.lowercased() != "time tbd" else {
            return nil
        }

        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd h:mm a"
        formatter.timeZone = TimeZone.current
        return formatter.date(from: "\(VenueDetailView.sqlDayFormatter.string(from: day)) \(time)")
    }

    private func venueEventDay(_ row: VenueEventRow) -> Date? {
        guard let date = trimmedNonEmpty(row.event_date) else { return nil }
        return VenueDetailView.sqlDayFormatter.date(from: date)
    }

    private func venueGameDateTimeText(start: Date?, day: Date?, timeText: String?) -> String {
        if let start {
            return start.formatted(date: .abbreviated, time: .shortened)
        }

        guard let day else { return "Time TBD" }
        let dateText = day.formatted(date: .abbreviated, time: .omitted)
        guard let time = trimmedNonEmpty(timeText), time.lowercased() != "time tbd" else {
            return "\(dateText) at Time TBD"
        }
        return "\(dateText) at \(time)"
    }

    private func venueGameStatus(start: Date?, now: Date) -> VenueDetailGameStatus? {
        guard let start else { return .confirmed }

        let liveEnd = start.addingTimeInterval(TimeInterval(FanGeoLiveEnergyTiming.liveWindowHours * 3600))
        if now >= start && now <= liveEnd { return .live }

        let secondsUntil = start.timeIntervalSince(now)
        if secondsUntil > 0 && secondsUntil <= TimeInterval(FanGeoLiveEnergyTiming.startsSoonWindowMinutes * 60) {
            return .startingSoon
        }

        return .confirmed
    }

    private func trimmedNonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func predictionTeams(for row: VenueEventRow) -> VenueEventPredictionTeams? {
        guard let home = trimmedNonEmpty(row.home_team),
              let away = trimmedNonEmpty(row.away_team) else {
            return nil
        }
        return VenueEventPredictionTeams(home: home, away: away)
    }

    private func predictionLoadToken(for games: [VenueDetailGameItem]) -> String {
        games
            .compactMap { game -> String? in
                guard game.supportsPredictions, let id = game.venueEventID else { return nil }
                return id.uuidString
            }
            .sorted()
            .joined(separator: "|")
    }

    private func openPredictionSheet(
        eventID: UUID,
        teams: VenueEventPredictionTeams,
        type: VenueEventPredictionType,
        isLocked: Bool
    ) {
        guard !isLocked else {
            predictionClosedMessage = "Predictions closed for this game."
            return
        }
        guard showsFanOnlyActionButtons else {
            onFanFeatureBlocked?("venuePrediction")
            return
        }
        predictionSheet = VenueDetailPredictionSheetContext(
            venueEventID: eventID,
            teams: teams,
            predictionType: type
        )
    }

    private func compactHeroBadge(_ title: String, tint: Color) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.26))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(tint.opacity(0.35), lineWidth: 1)
            }
            .clipShape(Capsule(style: .continuous))
    }

    private func logVenueDetailDebugState() {
#if DEBUG
        print("[VenueDetailDebug] isBusinessConfirmed=\(isBusinessConfirmed)")
        print("[VenueDetailDebug] selected venue business_id=\(bar.businessId?.uuidString ?? "nil")")
        print("[VenueDetailDebug] selected venue owner_email=\(bar.ownerEmail ?? "nil")")
        print("[VenueDetailDebug] selected venue sports_supported=\(sportsSupported)")
        print("[VenueDetailDebug] selected venue ratingCount=\(ratingCount)")
        let hero = venueDetailsHeroURLString ?? ""
        let second = venueDetailsSecondPhotoURLString ?? ""
        print("[VenuePhotoDisplayDebug] venueDetailsHeroURL=\(hero)")
        print("[VenuePhotoDisplayDebug] venueDetailsSecondPhotoURL=\(second)")
        print("[VenuePhotoDisplayDebug] usingThumbnail=\(venueDetailsHeroUsesThumbnail)")
        print("[VenuePhotoDisplayDebug] fallbackUsed=\(hero.isEmpty)")
        if let rating = resolvedRating {
            print("[VenueDetailDebug] selected venue ratingAverage=\(rating)")
        } else {
            print("[VenueDetailDebug] selected venue ratingAverage=nil")
        }
#endif
    }

    @ViewBuilder
    private var venueExperienceSection: some View {
        if let experience {
            FGCard {
                FGSectionHeader(
                    "Game day experience",
                    subtitle: "Atmosphere, crowd, audio, seating, and planning details"
                )

                VStack(spacing: FGSpacing.sm) {
                    experienceRow("Atmosphere", experience.atmosphere, "sparkles")
                    experienceRow("Crowd", experience.crowdLevel, "person.3.fill")
                    experienceRow("Fanbase", experience.teamFanbases.joined(separator: " • "), "flag.fill")
                    experienceRow(
                        "Audio",
                        experience.hasAudio ? "Sound will be on" : "No confirmed audio",
                        experience.hasAudio ? "speaker.wave.2.fill" : "speaker.slash.fill"
                    )
                    experienceRow("Drink specials", experience.drinkSpecials, "mug.fill")
                    experienceRow("Seating", experience.availableSeating, "chair.lounge.fill")
                    experienceRow("Cover", experience.coverCharge, "dollarsign.circle.fill")
                    experienceRow(
                        "Reservations",
                        experience.reservationsAvailable ? "Reservations available" : "No reservations",
                        "calendar.badge.clock"
                    )
                    experienceRow(
                        "Waitlist",
                        experience.waitlistAvailable ? "Waitlist available" : "No waitlist",
                        "list.bullet.clipboard"
                    )
                    experienceRow("Social", experience.socialCoordination, "person.2.wave.2.fill")
                }
            }
        }
    }

    private func experienceRow(_ title: String, _ value: String, _ icon: String) -> some View {
        HStack(alignment: .top, spacing: FGSpacing.md) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(FGColor.accentBlue)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: FGSpacing.xs) {
                Text(title)
                    .font(FGTypography.metadata)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))

                Text(value)
                    .font(FGTypography.body)
                    .foregroundStyle(FGColor.primaryText(colorScheme))
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(FGSpacing.md)
        .background(FGColor.background(colorScheme).opacity(colorScheme == .dark ? 0.60 : 0.92))
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
    }

    private var venueInfoSection: some View {
        FGCard {
            FGSectionHeader("Venue information", subtitle: "Address, contact, and watch setup")

            VStack(spacing: FGSpacing.sm) {
                infoRow(title: "Address", value: bar.address, icon: "mappin.and.ellipse") {
                    (onAddressTap ?? onDirections)()
                }

                infoRow(title: "Phone", value: bar.phone.isEmpty ? "Not listed" : BusinessPhoneFields.displayString(fromStored: bar.phone), icon: "phone.fill") {
                    onCall()
                }

                HStack(spacing: FGSpacing.sm) {
                    if let screenCount = bar.screenCount, screenCount > 0 {
                        FGStatusPill(title: VenueFeatureDefinitions.screenLabel(count: screenCount), kind: .custom(tint: FGColor.accentBlue))
                    }
                    if bar.servesFood == true {
                        FGStatusPill(title: VenueFeatureDefinitions.foodDrinks.label, kind: .custom(tint: FGColor.accentGreen))
                    }
                    if ImageDisplayURL.forDetail(thumbnail: nil, full: menuPhotoURL ?? bar.menuPhotoURL) != nil {
                        FGStatusPill(title: "Others", kind: .custom(tint: FGColor.accentYellow))
                    }
                }
            }
        }
    }

    private func infoRow(title: String, value: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: FGSpacing.md) {
                Image(systemName: icon)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(FGColor.accentBlue)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: FGSpacing.xs) {
                    Text(title)
                        .font(FGTypography.metadata)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                    Text(value)
                        .font(FGTypography.body)
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(FGSpacing.md)
            .background(FGColor.background(colorScheme).opacity(colorScheme == .dark ? 0.60 : 0.92))
            .clipShape(RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var venueFeaturesSection: some View {
        let items = venueFeatureItems

        return FGCard {
            FGSectionHeader(
                "Venue features",
                subtitle: bar.isCommunityVenue
                    ? "Amenities are unverified for this community venue"
                    : "What makes this spot easy to choose"
            )

            if bar.isCommunityVenue {
                HStack(spacing: 6) {
                    Image(systemName: "building.2.crop.circle")
                        .font(.caption.weight(.semibold))
                    Text("Community venue · unverified features")
                        .font(FGTypography.caption.weight(.semibold))
                }
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .padding(.bottom, 4)
            }

            VenueFeatureGrid(items: items)
        }
        .onAppear {
            logVenueFeaturesDebug(renderedItems: items)
        }
    }

    @ViewBuilder
    private var venueTagsSection: some View {
        if !bar.tags.isEmpty {
            FGCard {
                FGSectionHeader("Venue vibe", subtitle: "Quick tags fans can scan before they go")

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: FGSpacing.sm) {
                        ForEach(Array(bar.tags.enumerated()), id: \.offset) { _, tag in
                            FGStatusPill(title: tag, kind: .custom(tint: FGColor.accentBlue))
                        }
                    }
                }
            }
        }
    }
}

private struct VenueDetailGameItem: Identifiable {
    let id: String
    let venueEventID: UUID?
    let title: String
    let sport: String
    let teams: VenueEventPredictionTeams?
    let dateTimeText: String
    let sortDate: Date
    let startsAt: Date?
    let status: VenueDetailGameStatus?

    var predictionsLocked: Bool {
        guard let startsAt else { return false }
        return Date() > startsAt.addingTimeInterval(10 * 60)
    }

    var supportsPredictions: Bool {
        guard venueEventID != nil, teams != nil else { return false }
        return Self.supportedPredictionSports.contains(Self.normalizedSport(sport))
    }

    private static let supportedPredictionSports: Set<String> = [
        "soccer",
        "baseball",
        "football",
        "hockey"
    ]

    private static func normalizedSport(_ value: String) -> String {
        let lowered = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowered.contains("soccer") { return "soccer" }
        if lowered.contains("baseball") { return "baseball" }
        if lowered.contains("football") || lowered == "nfl" || lowered == "college football" { return "football" }
        if lowered.contains("hockey") || lowered == "nhl" { return "hockey" }
        return lowered
    }
}

private struct VenueDetailPredictionSheetContext: Identifiable {
    let venueEventID: UUID
    let teams: VenueEventPredictionTeams
    let predictionType: VenueEventPredictionType

    var id: String {
        "\(venueEventID.uuidString.lowercased())|\(predictionType.rawValue)"
    }
}

private enum VenueDetailGameStatus {
    case confirmed
    case live
    case startingSoon

    var title: String {
        switch self {
        case .confirmed:
            return "Confirmed"
        case .live:
            return "Live"
        case .startingSoon:
            return "Starting soon"
        }
    }

    var tint: Color {
        switch self {
        case .confirmed:
            return FGColor.accentBlue
        case .live:
            return FGColor.dangerRed
        case .startingSoon:
            return FGColor.accentYellow
        }
    }
}

struct PreviewProvider_VenueDetailView: PreviewProvider {
    static var previews: some View {
        VenueDetailView(
            bar: SampleData.bars[0],
            selectedEvent: SampleData.events[0],
            isFavorite: false,
            goingCount: 12,
            iconForSport: { _ in "sportscourt.fill" },
            onDirections: {},
            onCall: {},
            onFavorite: {},
            experience: SampleData.venueExperiences[0]
        )
    }
}
