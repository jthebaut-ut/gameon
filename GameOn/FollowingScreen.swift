import CoreLocation
import MapKit
import SwiftUI

struct FollowingScreen: View {
    @ObservedObject var viewModel: MapViewModel
    var suppressInitialAutoRefresh = false

    @Environment(\.colorScheme) private var followingColorScheme
    @State private var favoriteActionBanner: String?
    @State private var didHandleInitialAutoRefresh = false

    /// Venue events the user marked "Interested" from Following without a Supabase row (table has no status column).
    @AppStorage("gameon.following.interestedOnlyVenueEventIDs") private var interestedOnlyEncoded: String = ""
    @State private var followingSegment: FollowingScreenMainTab = .venueGames
    @State private var pickupDetailNav: PickupDetailNavigationToken?

    private enum FollowingScreenMainTab: Int, CaseIterable, Identifiable, Hashable {
        case venueGames
        case savedVenues
        case gamesToPlay

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .venueGames: return "Venue Games"
            case .savedVenues: return "Saved Venues"
            case .gamesToPlay: return "Games to Play"
            }
        }
    }

    var body: some View {
        ZStack {
            Color.clear
                .fanGeoScreenBackground()
                .ignoresSafeArea()

            if viewModel.isAuthenticatedForSocialFeatures {
                loggedInContent
            } else {
                loggedOutContent
            }
        }
        .onAppear {
            if suppressInitialAutoRefresh && !didHandleInitialAutoRefresh {
                didHandleInitialAutoRefresh = true
                return
            }
            guard viewModel.isAuthenticatedForSocialFeatures else { return }
            Task { await reloadFollowingDataForCurrentUser() }
        }
        .onChange(of: viewModel.currentUserAuthId) { _, newId in
            if newId != nil {
                Task { await reloadFollowingDataForCurrentUser() }
            } else {
                clearFollowingUserSpecificState()
                interestedOnlyEncoded = ""
            }
        }
        .task(id: viewModel.currentUserAuthId) {
            guard viewModel.isAuthenticatedForSocialFeatures else { return }
            await viewModel.refreshFollowingTabDataGlobally()
            await viewModel.loadMyPickupGameJoinRequestsForFollowing()
        }
        .sheet(item: $pickupDetailNav, onDismiss: {
            Task { await viewModel.loadMyPickupGameJoinRequestsForFollowing() }
        }) { token in
            DiscoverPickupGameDetailSheet(viewModel: viewModel, gameId: token.id)
        }
        .onChange(of: viewModel.isAuthenticatedForSocialFeatures) { _, _ in
            Task { await syncFollowingAfterAuthChange() }
        }
    }

    /// Reload Following when fan or business-owner auth changes while a Supabase session may already exist.
    private func syncFollowingAfterAuthChange() async {
        if viewModel.isAuthenticatedForSocialFeatures {
            await reloadFollowingDataForCurrentUser()
        } else {
            clearFollowingUserSpecificState()
            interestedOnlyEncoded = ""
        }
    }

    // MARK: - Logged out

    private var loggedOutContent: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 24)

            FanGeoBrandHeroView(
                title: "Sign in required",
                subtitle: "Sign in to save venues and track games you plan to attend.",
                variant: followingColorScheme == .dark ? .white : .dark,
                logoWidth: 128,
                alignment: .center,
                textAlignment: .center
            )
            .padding(.horizontal, 28)

            Button {
                viewModel.discoverNavigateToAccountForUserAuth = true
            } label: {
                Text("Sign in or create account")
                    .font(.headline)
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.accentColor)
            .padding(.horizontal, 28)
            .padding(.top, 8)

            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 110)
    }

    // MARK: - Logged in

    private var loggedInContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Following")
                    .font(FGTypography.screenTitle)
                    .foregroundStyle(FGColor.primaryText(followingColorScheme))
                    .padding(.top, 8)

                Text("Venue games you follow, saved spots, and pickup games you’ve asked to join.")
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(followingColorScheme))
                    .fixedSize(horizontal: false, vertical: true)

                if let favoriteActionBanner {
                    Text(favoriteActionBanner)
                        .font(FGTypography.metadata)
                        .fontWeight(.semibold)
                        .foregroundStyle(FGColor.accentYellow)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(FGColor.accentYellow.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: FGRadius.small, style: .continuous))
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.horizontal, FGSpacing.md)

            Picker("Following section", selection: $followingSegment) {
                ForEach(FollowingScreenMainTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, FGSpacing.md)
            .padding(.top, 12)
            .padding(.bottom, 8)

            ScrollView {
                followingSegmentContent
                    .padding(.horizontal, FGSpacing.md)
                    .padding(.bottom, 110)
            }
            .refreshable {
                async let venues: Void = viewModel.refreshFollowingTabDataGlobally()
                async let pickup: Void = viewModel.loadMyPickupGameJoinRequestsForFollowing()
                await venues
                await pickup
            }
        }
    }

    @ViewBuilder
    private var followingSegmentContent: some View {
        switch followingSegment {
        case .venueGames:
            venueGamesTabContent
        case .savedVenues:
            savedVenuesTabContent
        case .gamesToPlay:
            gamesToPlayTabContent
        }
    }

    private var venueGamesTabContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if viewModel.followingTabGoingItems.isEmpty {
                emptyCard(
                    icon: "sportscourt.fill",
                    title: "No venue game plans",
                    subtitle: "Save a venue and tap “I’m going” on a game to see it here."
                )
            } else {
                VStack(spacing: 12) {
                    ForEach(viewModel.followingTabGoingItems) { item in
                        goingPlanCard(item)
                    }
                }
            }
        }
        .padding(.top, 6)
    }

    private var savedVenuesTabContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if viewModel.followingTabSavedVenues.isEmpty {
                emptyCard(
                    icon: "heart",
                    title: "No saved venues",
                    subtitle: "Tap the heart on a venue in Discover to save it."
                )
            } else {
                VStack(spacing: 12) {
                    ForEach(viewModel.followingTabSavedVenues) { bar in
                        venueCard(bar)
                    }
                }
                .animation(.spring(response: 0.36, dampingFraction: 0.86), value: viewModel.favoriteVenueIDs)
            }
        }
        .padding(.top, 6)
    }

    private var gamesToPlayTabContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if viewModel.myPickupGameJoinRequestCards.isEmpty {
                emptyCard(
                    icon: "figure.run",
                    title: "No pickup games yet",
                    subtitle: "Request to join a pickup game from Discover — it will show up here with status updates."
                )
            } else {
                VStack(spacing: 12) {
                    ForEach(viewModel.myPickupGameJoinRequestCards) { card in
                        pickupGameJoinCard(card)
                    }
                }
            }
        }
        .padding(.top, 6)
    }

    // MARK: - Session / cache (Following tab only)

    private func clearFollowingUserSpecificState() {
        viewModel.clearFollowingTabCaches()
        viewModel.favoriteVenueIDs = []
        viewModel.venueEventInterestIDs = []
        viewModel.interestedVenueEventKeys = []
    }

    private func reloadFollowingDataForCurrentUser() async {
        await viewModel.refreshFollowingTabDataGlobally()
        await viewModel.loadMyPickupGameJoinRequestsForFollowing()
    }

    // MARK: - Attendance actions

    private func setInterestedOnlyLocally(_ venueEventID: UUID, _ add: Bool) {
        var set = decodeInterestedOnlyUUIDs(from: interestedOnlyEncoded)
        if add {
            set.insert(venueEventID)
        } else {
            set.remove(venueEventID)
        }
        interestedOnlyEncoded = encodeInterestedOnlyUUIDs(set)
    }

    @MainActor
    private func applyAttendance(_ item: FollowingGoingDisplayItem, target: FollowingAttendanceTarget) async {
        guard viewModel.isAuthenticatedForSocialFeatures else { return }

        let localInterested = decodeInterestedOnlyUUIDs(from: interestedOnlyEncoded)
        let previousInterestedOnly = interestedOnlyEncoded
        let ok: Bool

#if DEBUG
        print("[FollowingState] attendance action event=\(item.id.uuidString) action=\(target)")
#endif

        switch target {
        case .going:
            if item.isServerGoing, !localInterested.contains(item.id) { return }
            setInterestedOnlyLocally(item.id, false)
            ok = await viewModel.markInterestedInVenueEvent(venueEventID: item.id, refreshFollowing: true)
        case .interested:
            if !item.isServerGoing, localInterested.contains(item.id) { return }
            setInterestedOnlyLocally(item.id, true)
            ok = await viewModel.removeInterestInVenueEvent(venueEventID: item.id, refreshFollowing: true)
        case .notGoing:
            guard item.isServerGoing || localInterested.contains(item.id) else { return }
            setInterestedOnlyLocally(item.id, false)
            ok = await viewModel.removeInterestInVenueEvent(venueEventID: item.id, refreshFollowing: true)
        }

        guard ok else {
#if DEBUG
            print("[FollowingState] attendance update failed event=\(item.id.uuidString) action=\(target)")
#endif
            interestedOnlyEncoded = previousInterestedOnly
            viewModel.showSocialActionToast("Couldn't update your game plan.")
            return
        }
#if DEBUG
        switch target {
        case .going:
            print("[FollowingState] marked going")
        case .interested:
            print("[FollowingState] marked interested")
        case .notGoing:
            print("[FollowingState] marked not going, removed from following")
        }
#endif
    }

    // MARK: - Shared UI pieces

    private func pickupGameJoinCard(_ card: PickupGameJoinRequestCardDisplay) -> some View {
        let sportVisual = SportFilterCatalog.resolve(card.sport)

        return VStack(alignment: .leading, spacing: FGSpacing.sm) {
            HStack(alignment: .top, spacing: FGSpacing.sm) {
                Image(systemName: sportVisual.systemImage)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(sportVisual.accent)
                    .frame(width: 40, height: 40)
                    .background(sportVisual.accent.opacity(0.14), in: Circle())

                VStack(alignment: .leading, spacing: 6) {
                    Text(card.title)
                        .font(FGTypography.cardTitle)
                        .foregroundStyle(FGColor.primaryText(followingColorScheme))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    pickupJoinStatusPill(card.pill)
                }
                Spacer(minLength: 0)
            }

            if !card.dateTimeLine.isEmpty {
                Label(card.dateTimeLine, systemImage: "calendar")
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(followingColorScheme))
            }
            if !card.locationLine.isEmpty {
                Label(card.locationLine, systemImage: "mappin.and.ellipse")
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(followingColorScheme))
                    .lineLimit(2)
            }

            HStack(spacing: FGSpacing.sm) {
                UserAvatarView(
                    avatarThumbnailURL: viewModel.pickupOrganizerAvatarThumbnailForDetail(userId: card.organizerUserId),
                    avatarURL: viewModel.pickupOrganizerAvatarFullForDetail(userId: card.organizerUserId),
                    avatarDisplayRefreshToken: viewModel.pickupOrganizerAvatarRefreshTokenForDetail(userId: card.organizerUserId),
                    displayName: card.organizerName,
                    email: viewModel.pickupOrganizerEmailForDetail(userId: card.organizerUserId),
                    size: 36,
                    fallbackStyle: followingColorScheme == .dark ? .darkCardTranslucent : .lightOnWhiteChrome
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text("Organizer")
                        .font(FGTypography.metadata)
                        .foregroundStyle(FGColor.mutedText(followingColorScheme))
                    Text(card.organizerName)
                        .font(FGTypography.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(FGColor.primaryText(followingColorScheme))
                }
                Spacer(minLength: 0)
            }

            if let spots = card.spotsRemainingSummary, !spots.isEmpty {
                Text(spots)
                    .font(FGTypography.metadata)
                    .foregroundStyle(FGColor.mutedText(followingColorScheme))
            }

            Button {
                pickupDetailNav = PickupDetailNavigationToken(id: card.pickupGameId)
            } label: {
                Text("View Details")
                    .font(FGTypography.caption)
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(FGColor.accentBlue)
        }
        .padding(FGSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FGColor.cardBackground(followingColorScheme))
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.card, style: .continuous))
        .modifier(FollowingCardChromeModifier(colorScheme: followingColorScheme))
        .overlay {
            if let border = pickupCardAccentBorder(card) {
                RoundedRectangle(cornerRadius: FGRadius.card, style: .continuous)
                    .strokeBorder(border, lineWidth: card.pill == .approved ? 1.5 : 1.25)
            }
        }
        .task(id: card.organizerUserId) {
            await viewModel.loadPickupCreatorDisplayNameIfNeeded(creatorUserId: card.organizerUserId)
        }
    }

    private func pickupCardAccentBorder(_ card: PickupGameJoinRequestCardDisplay) -> Color? {
        switch card.pill {
        case .approved: return FGColor.accentGreen.opacity(0.38)
        case .declined: return FGColor.divider(followingColorScheme)
        default: return nil
        }
    }

    private func pickupJoinStatusPill(_ pill: PickupFollowingJoinRequestPillKind) -> some View {
        let colors = pickupJoinPillColors(pill)
        return Text(pill.title)
            .font(FGTypography.metadata)
            .fontWeight(.semibold)
            .foregroundStyle(colors.foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(colors.background)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(colors.stroke, lineWidth: 1))
    }

    private func pickupJoinPillColors(_ pill: PickupFollowingJoinRequestPillKind) -> (background: Color, foreground: Color, stroke: Color) {
        switch pill {
        case .pending:
            return (
                FGColor.accentYellow.opacity(followingColorScheme == .dark ? 0.22 : 0.18),
                followingColorScheme == .dark ? Color.white.opacity(0.92) : Color.orange.opacity(0.95),
                FGColor.accentYellow.opacity(0.55)
            )
        case .approved:
            return (
                FGColor.accentGreen.opacity(0.16),
                FGColor.accentGreen,
                FGColor.accentGreen.opacity(0.42)
            )
        case .declined:
            return (
                Color.gray.opacity(followingColorScheme == .dark ? 0.22 : 0.14),
                FGColor.secondaryText(followingColorScheme),
                FGColor.divider(followingColorScheme)
            )
        case .cancelled:
            return (
                Color.gray.opacity(0.12),
                FGColor.mutedText(followingColorScheme),
                FGColor.divider(followingColorScheme).opacity(0.75)
            )
        }
    }

    private func emptyCard(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.largeTitle)
                .foregroundStyle(FGColor.secondaryText(followingColorScheme))

            Text(title)
                .font(FGTypography.cardTitle)
                .foregroundStyle(FGColor.primaryText(followingColorScheme))

            Text(subtitle)
                .font(FGTypography.caption)
                .foregroundStyle(FGColor.secondaryText(followingColorScheme))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(FGColor.cardBackground(followingColorScheme))
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.card, style: .continuous))
        .modifier(FollowingCardChromeModifier(colorScheme: followingColorScheme))
    }

    private func goingPlanCard(_ item: FollowingGoingDisplayItem) -> some View {
        let title = item.venueEvent.event_title ?? "Event"
        let bar = item.bar

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Text(title)
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 8)

                attendanceMenu(item: item)
            }

            let datePart = item.venueEvent.event_date ?? ""
            let timePart = item.venueEvent.event_time ?? ""
            if !datePart.isEmpty || !timePart.isEmpty {
                Text([datePart, timePart].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
#if DEBUG
                let matched = viewModel.bars.contains(where: { $0.id == bar.id })
                print("[FollowingVenueOpen] venue=\(bar.name) matched=\(matched ? "mapRow" : "offMap")")
#endif
                viewModel.requestDiscoverFocusForSavedVenue(bar)
            } label: {
                Text(bar.name)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(bar.name) on map")

            Button {
                openFollowingDirectionsToVenue(bar: bar)
            } label: {
                Text(bar.address)
                    .font(.caption)
                    .foregroundStyle(.blue)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Directions to \(bar.name)")

            HStack(spacing: 10) {
                GoingAvatarStack(profiles: viewModel.goingProfiles(for: item.id))
                Label("\(item.attendeeCount) people interested / going", systemImage: "person.3.fill")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundStyle(.green)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FGColor.cardBackground(followingColorScheme))
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.card, style: .continuous))
        .modifier(FollowingCardChromeModifier(colorScheme: followingColorScheme))
        .task(id: item.id) {
            guard viewModel.isAuthenticatedForSocialFeatures else { return }
            await viewModel.loadGoingUserProfiles(for: item.id)
        }
    }

    @ViewBuilder
    private func attendanceMenu(item: FollowingGoingDisplayItem) -> some View {
        if viewModel.isAuthenticatedForSocialFeatures {
            Menu {
                Button {
                    Task { await applyAttendance(item, target: .going) }
                } label: {
                    Label("Going ✅", systemImage: "checkmark.circle.fill")
                }

                Button {
                    Task { await applyAttendance(item, target: .interested) }
                } label: {
                    Label("Interested 👀", systemImage: "eye")
                }

                Button(role: .destructive) {
                    Task { await applyAttendance(item, target: .notGoing) }
                } label: {
                    Label("Not going ❌", systemImage: "xmark.circle")
                }
            } label: {
                attendancePill(item: item)
            }
            .buttonStyle(.plain)
        } else {
            attendancePill(item: item)
                .opacity(0.45)
        }
    }

    private func attendancePill(item: FollowingGoingDisplayItem) -> some View {
        let isGoing = item.isServerGoing
        return HStack(spacing: 6) {
            Text(isGoing ? "Going" : "Interested")
                .font(.caption)
                .fontWeight(.bold)
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.bold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            Capsule()
                .fill(isGoing ? Color.green.opacity(0.22) : Color.orange.opacity(0.22))
        )
        .overlay(
            Capsule()
                .strokeBorder(isGoing ? Color.green.opacity(0.45) : Color.orange.opacity(0.45), lineWidth: 1)
        )
        .foregroundStyle(isGoing ? Color.green : Color.orange)
    }

    private func venueCard(_ bar: BarVenue) -> some View {
        let isFavorite = viewModel.favoriteVenueIDs.contains(bar.id)

        return ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    viewModel.requestDiscoverFocusForSavedVenue(bar)
                } label: {
                    Text(bar.name)
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(bar.name) on map")

                Button {
                    openFollowingDirectionsToVenue(bar: bar)
                } label: {
                    Text(bar.address)
                        .font(.caption)
                        .foregroundStyle(.blue)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                Button {
                    viewModel.requestDiscoverFocusForSavedVenue(bar)
                } label: {
                    FlowTags(tags: bar.tags)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Button {
                Task { await toggleSavedVenueHeart(bar: bar, currentlySaved: isFavorite) }
            } label: {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .font(.title3)
                    .foregroundStyle(isFavorite ? Color.red : Color.secondary)
                    .padding(10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isFavorite ? "Remove from saved venues" : "Save venue")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FGColor.cardBackground(followingColorScheme))
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.card, style: .continuous))
        .modifier(FollowingCardChromeModifier(colorScheme: followingColorScheme))
    }

    // MARK: - Maps / Discover (Following tab)

    /// Opens Apple Maps directions: uses venue coordinates when they look valid; otherwise falls back to encoded address (`daddr`).
    private func openFollowingDirectionsToVenue(bar: BarVenue) {
#if DEBUG
        print("[FollowingDirections] venue=\(bar.name) address=\(bar.address)")
#endif
        let trimmedAddress = bar.address.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.followingDirectionsCoordinateLooksUsable(bar.coordinate) {
            let mapItem = MKMapItem(placemark: MKPlacemark(coordinate: bar.coordinate))
            mapItem.name = bar.name
            mapItem.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
            return
        }
        guard !trimmedAddress.isEmpty else { return }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "maps.apple.com"
        components.queryItems = [URLQueryItem(name: "daddr", value: trimmedAddress)]
        guard let url = components.url else { return }
        UIApplication.shared.open(url)
    }

    private static func followingDirectionsCoordinateLooksUsable(_ c: CLLocationCoordinate2D) -> Bool {
        guard CLLocationCoordinate2DIsValid(c) else { return false }
        if abs(c.latitude) < 1e-5 && abs(c.longitude) < 1e-5 { return false }
        return abs(c.latitude) <= 90 && abs(c.longitude) <= 180
    }

    private func toggleSavedVenueHeart(bar: BarVenue, currentlySaved: Bool) async {
        guard viewModel.isAuthenticatedForSocialFeatures else { return }
        let wantSave = !currentlySaved
        let ok = await viewModel.setVenueFavorite(bar: bar, isFavorite: wantSave)
        if !ok {
            await MainActor.run {
                favoriteActionBanner = "Couldn’t update saved venue. Try again."
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
                    favoriteActionBanner = nil
                }
            }
        }
    }
}

/// Premium separation for Following list cards on `systemGroupedBackground` (stroke, soft lift, top-edge sheen).
private struct FollowingCardChromeModifier: ViewModifier {
    var colorScheme: ColorScheme
    private let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)

    func body(content: Content) -> some View {
        let isLight = colorScheme == .light
        let shadowColor = Color.black.opacity(isLight ? 0.125 : 0.32)
        let shadowRadius: CGFloat = isLight ? 12 : 8
        let shadowY: CGFloat = isLight ? 3 : 2
        let outerStroke = FGColor.divider(colorScheme).opacity(isLight ? 0.92 : 0.88)
        let innerStroke = Color.white.opacity(isLight ? 0.10 : 0.04)
        let sheenTop = Color.white.opacity(isLight ? 0.16 : 0.04)

        content
            .shadow(color: shadowColor, radius: shadowRadius, x: 0, y: shadowY)
            .overlay {
                ZStack {
                    shape
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: sheenTop, location: 0),
                                    .init(color: Color.clear, location: 0.2)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .blendMode(.overlay)
                    shape
                        .strokeBorder(innerStroke, lineWidth: 0.5)
                        .padding(1)
                    shape
                        .strokeBorder(outerStroke, lineWidth: 1.35)
                }
                .allowsHitTesting(false)
            }
    }
}

private enum FollowingAttendanceTarget {
    case going
    case interested
    case notGoing
}

private func decodeInterestedOnlyUUIDs(from encoded: String) -> Set<UUID> {
    let parts = encoded.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    var out: Set<UUID> = []
    for p in parts {
        if let u = UUID(uuidString: p) {
            out.insert(u)
        }
    }
    return out
}

private func encodeInterestedOnlyUUIDs(_ set: Set<UUID>) -> String {
    set.map(\.uuidString).sorted().joined(separator: ",")
}
