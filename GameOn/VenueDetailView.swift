import SwiftUI

struct VenueDetailView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var showClaimConfirmation = false
    @State private var claimActionError: String?

    let bar: BarVenue
    let selectedEvent: SportsEvent?
    let isFavorite: Bool
    let goingCount: Int
    let iconForSport: (String) -> String
    /// When nil, no rating card is shown.
    var mergedRating: Double? = nil
    var ratingCount: Int = 0
    var displaySport: String? = nil
    var sportsSupported: [String] = []
    var hasGamesScheduledToday: Bool = true
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
        guard let raw = ImageDisplayURL.forDetail(
            thumbnail: bar.coverPhotoThumbnailURL ?? bar.menuPhotoThumbnailURL,
            full: coverPhotoURL ?? bar.coverPhotoURL ?? menuPhotoURL ?? bar.menuPhotoURL
        ), let url = URL(string: raw) else {
            return nil
        }
        return url
    }

    private var venueShareText: String {
        var lines = [bar.name, bar.address]
        if let selectedEvent {
            lines.append("Catch \(selectedEvent.title) on \(selectedEvent.date.formatted(date: .abbreviated, time: .omitted)) at \(selectedEvent.time)")
        }
        lines.append("Shared from FanGeo")
        return lines.joined(separator: "\n")
    }

    private var venueFeatureItems: [(icon: String, title: String, enabled: Bool)] {
        [
            ("display", "\(bar.screenCount) Screens", true),
            ("fork.knife", "Food / Drinks", bar.servesFood),
            ("wifi", "WiFi", bar.hasWifi),
            ("chair.lounge.fill", "Patio", bar.hasGarden),
            ("video.fill", "Projector", bar.hasProjector),
            ("pawprint.fill", "Pet Friendly", bar.petFriendly)
        ]
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
            VStack(alignment: .leading, spacing: FGSpacing.xl) {
                venueHeroSection
                venueStatsSection
                venueActionSection
                venueFanActivitySection
                venueBusinessClaimSection
                venueGamesSection
                venueExperienceSection
                venueInfoSection
                venueFeaturesSection
                venueTagsSection
            }
            .frame(maxWidth: 680, alignment: .top)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.horizontal, 22)
            .padding(.top, FGSpacing.lg)
            .padding(.bottom, 132)
        }
        .scrollIndicators(.hidden)
        .fanGeoScreenBackground()
        .onAppear(perform: logVenueDetailDebugState)
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
    }

    private var venueHeroSection: some View {
        ZStack(alignment: .topTrailing) {
            heroBackground

            LinearGradient(
                colors: [Color.black.opacity(0.08), Color.black.opacity(0.58)],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: FGSpacing.lg) {
                HStack(alignment: .top, spacing: FGSpacing.md) {
                    if isBusinessConfirmed || hasDisplaySport {
                        HStack(spacing: 6) {
                            if isBusinessConfirmed {
                                compactHeroBadge("Confirmed Venue", tint: FGColor.accentGreen)
                            }
                            if let displaySport, hasDisplaySport {
                                compactHeroBadge(displaySport, tint: FGColor.accentBlue)
                            }
                        }
                    }

                    Spacer(minLength: FGSpacing.md)

                    Button(action: onFavorite) {
                        Image(systemName: isFavorite ? "heart.fill" : "heart")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(isFavorite ? Color.red : Color.white)
                            .frame(width: 44, height: 44)
                            .background(Color.black.opacity(0.25))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: FGSpacing.sm) {
                    Text(bar.name)
                        .font(FGTypography.heroTitle)
                        .foregroundStyle(.white)
                        .lineLimit(2)

                    Button {
                        (onAddressTap ?? onDirections)()
                    } label: {
                        HStack(alignment: .top, spacing: FGSpacing.sm) {
                            Image(systemName: "mappin.and.ellipse")
                                .font(.body.weight(.semibold))
                            Text(bar.address)
                                .font(FGTypography.body)
                                .multilineTextAlignment(.leading)
                        }
                        .foregroundStyle(.white.opacity(0.92))
                    }
                    .buttonStyle(.plain)

                    HStack(spacing: FGSpacing.sm) {
                        if !bar.distance.isEmpty {
                            FGStatusPill(title: bar.distance, kind: .custom(tint: FGColor.accentYellow))
                        }
                        FGStatusPill(
                            title: "\(bar.screenCount) screens",
                            kind: .custom(tint: FGColor.businessGreen)
                        )
                    }
                }
            }
            .padding(FGSpacing.lg)
        }
        .frame(height: 238)
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
                colors: [Color.black.opacity(0.92), FGColor.gradientEnd.opacity(0.78)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: FGSpacing.sm) {
                Image(systemName: heroFallbackIconName)
                    .font(.system(size: 52, weight: .bold))
                    .foregroundStyle(.white)
                Text(hasGamesScheduledToday ? "Game-day ready" : "No games scheduled today")
                    .font(FGTypography.sectionTitle)
                    .foregroundStyle(.white)
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
                Button(action: onRateVenue) {
                    statCard(
                        title: String(format: "%.1f", rating),
                        subtitle: ratingSubtitle,
                        icon: "star.fill",
                        tint: FGColor.accentYellow
                    )
                }
                .buttonStyle(.plain)
            } else if let rating = resolvedRating {
                statCard(
                    title: String(format: "%.1f", rating),
                    subtitle: ratingSubtitle,
                    icon: "star.fill",
                    tint: FGColor.accentYellow
                )
            }
            if let displaySport, hasDisplaySport {
                statCard(
                    title: displaySport,
                    subtitle: "Sport",
                    icon: iconForSport(displaySport),
                    tint: FGColor.businessGreen
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

    private var venueActionSection: some View {
        FGCard {
            FGSectionHeader("Quick actions", subtitle: "Get there, call, save, or share this venue")

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: FGSpacing.md),
                    GridItem(.flexible(), spacing: FGSpacing.md)
                ],
                spacing: FGSpacing.md
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

                Button(action: onFavorite) {
                    actionCardContent(
                        title: isFavorite ? "Saved" : "Save",
                        subtitle: isFavorite ? "In favorites" : "Pin this venue",
                        icon: isFavorite ? "heart.fill" : "heart",
                        tint: Color.red
                    )
                }
                .buttonStyle(.plain)

                ShareLink(item: venueShareText) {
                    actionCardContent(
                        title: "Share",
                        subtitle: "Send venue",
                        icon: "square.and.arrow.up",
                        tint: FGColor.accentYellow
                    )
                }
            }
        }
    }

    private func actionCardContent(title: String, subtitle: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: FGSpacing.sm) {
            Image(systemName: icon)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(FGTypography.cardTitle)
                .foregroundStyle(FGColor.primaryText(colorScheme))
            Text(subtitle)
                .font(FGTypography.caption)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
        }
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
        .padding(FGSpacing.lg)
        .background(FGColor.background(colorScheme).opacity(colorScheme == .dark ? 0.60 : 0.92))
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var venueFanActivitySection: some View {
        if selectedEvent != nil || goingCount > 0 {
            FGCard {
                FGSectionHeader(
                    "Venue buzz",
                    subtitle: selectedEvent.map { "Fan activity for \($0.title)" } ?? "Current venue activity"
                )

                if let selectedEvent {
                    HStack(spacing: FGSpacing.sm) {
                        FGStatusPill(title: selectedEvent.sport, kind: .custom(tint: FGColor.accentBlue))
                        Text("\(selectedEvent.date.formatted(date: .abbreviated, time: .omitted)) at \(selectedEvent.time)")
                            .font(FGTypography.caption)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    }
                }

                if goingCount > 0, let selectedEvent {
                    HStack(alignment: .top, spacing: FGSpacing.md) {
                        Image(systemName: "person.3.fill")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(FGColor.accentGreen)

                        VStack(alignment: .leading, spacing: FGSpacing.xs) {
                            Text("\(goingCount) people interested / going")
                                .font(FGTypography.cardTitle)
                                .foregroundStyle(FGColor.primaryText(colorScheme))
                            Text("Fans are rallying here for \(selectedEvent.title).")
                                .font(FGTypography.caption)
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(FGSpacing.lg)
                    .background(FGColor.accentGreen.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous))
                } else {
                    FGEmptyState(
                        title: "No fan activity yet",
                        subtitle: "Once fans start planning around this venue, activity will appear here.",
                        systemImage: "person.3"
                    )
                }
            }
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
        FGCard {
            FGSectionHeader(
                "Games showing",
                subtitle: hasGamesScheduledToday ? "Confirmed venue lineup" : "No games scheduled today"
            )

            if !hasGamesScheduledToday {
                FGEmptyState(
                    title: "No games scheduled today",
                    subtitle: "This venue is active on the map, but there are no scheduled broadcasts or venue events for the selected day.",
                    systemImage: "calendar.badge.exclamationmark"
                )
            } else if bar.games.isEmpty {
                FGEmptyState(
                    title: "No games listed yet",
                    subtitle: "Check back soon for confirmed watch parties and broadcasts.",
                    systemImage: "tv"
                )
            } else {
                VStack(spacing: FGSpacing.md) {
                    ForEach(Array(bar.games.enumerated()), id: \.offset) { _, game in
                        gameCard(game)
                    }
                }
            }
        }
    }

    private func gameCard(_ game: String) -> some View {
        let isSelectedGame = selectedEvent?.title == game
        let selectedSport = selectedEvent?.sport ?? displaySport ?? ""

        return VStack(alignment: .leading, spacing: FGSpacing.sm) {
            HStack(alignment: .top, spacing: FGSpacing.md) {
                Image(systemName: isSelectedGame ? iconForSport(selectedSport) : "tv.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(isSelectedGame ? FGColor.accentGreen : FGColor.accentBlue)

                VStack(alignment: .leading, spacing: FGSpacing.xs) {
                    Text(game)
                        .font(FGTypography.cardTitle)
                        .foregroundStyle(FGColor.primaryText(colorScheme))

                    if isSelectedGame, let selectedEvent {
                        Text("\(selectedEvent.date.formatted(date: .abbreviated, time: .omitted)) at \(selectedEvent.time)")
                            .font(FGTypography.caption)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    } else {
                        Text("Venue-confirmed broadcast")
                            .font(FGTypography.caption)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    }
                }

                Spacer(minLength: FGSpacing.sm)

                FGStatusPill(
                    title: isSelectedGame ? "Selected" : "Confirmed",
                    kind: .custom(tint: isSelectedGame ? FGColor.accentGreen : FGColor.accentBlue)
                )
            }

            if isSelectedGame, goingCount > 0 {
                HStack(spacing: FGSpacing.sm) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .foregroundStyle(FGColor.accentBlue)
                    Text("\(goingCount) fans interested / going")
                        .font(FGTypography.metadata)
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(FGSpacing.lg)
        .background(FGColor.background(colorScheme).opacity(colorScheme == .dark ? 0.60 : 0.92))
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
        }
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
                    FGStatusPill(title: "\(bar.screenCount) screens", kind: .custom(tint: FGColor.accentBlue))
                    if bar.servesFood {
                        FGStatusPill(title: "Food + drinks", kind: .custom(tint: FGColor.accentGreen))
                    }
                    if ImageDisplayURL.forDetail(thumbnail: nil, full: menuPhotoURL ?? bar.menuPhotoURL) != nil {
                        FGStatusPill(title: "Menu photo", kind: .custom(tint: FGColor.accentYellow))
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
        FGCard {
            FGSectionHeader("Venue features", subtitle: "Amenities and comfort at a glance")

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: FGSpacing.sm),
                    GridItem(.flexible(), spacing: FGSpacing.sm),
                    GridItem(.flexible(), spacing: FGSpacing.sm)
                ],
                spacing: FGSpacing.sm
            ) {
                ForEach(venueFeatureItems.indices, id: \.self) { index in
                    let item = venueFeatureItems[index]
                    VStack(spacing: FGSpacing.xs) {
                        Image(systemName: item.icon)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(item.enabled ? FGColor.accentGreen : FGColor.mutedText(colorScheme))
                        Text(item.title)
                            .font(FGTypography.caption)
                            .foregroundStyle(item.enabled ? FGColor.primaryText(colorScheme) : FGColor.secondaryText(colorScheme))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity, minHeight: 84)
                    .padding(.horizontal, FGSpacing.xs)
                    .background(
                        item.enabled
                            ? FGColor.accentGreen.opacity(0.10)
                            : FGColor.background(colorScheme).opacity(colorScheme == .dark ? 0.55 : 0.92)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
                }
            }
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
