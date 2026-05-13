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

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
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
            Task { await viewModel.refreshFollowingTabDataGlobally() }
        }
        .onChange(of: viewModel.currentUserAuthId) { _, newId in
            if newId != nil {
                Task { await reloadFollowingDataForCurrentUser() }
            } else {
                clearFollowingUserSpecificState()
                interestedOnlyEncoded = ""
            }
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
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                Text("Following")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundStyle(.primary)
                    .padding(.top, 22)

                Text("Your saved venues and games you plan to attend.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let favoriteActionBanner {
                    Text(favoriteActionBanner)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.orange.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                sectionTitle("I’m Going")

                if viewModel.followingTabGoingItems.isEmpty {
                    emptyCard(
                        icon: "person.badge.plus",
                        title: "No plans yet",
                        subtitle: "Tap “I’m going” on a venue event to add it here."
                    )
                } else {
                    VStack(spacing: 12) {
                        ForEach(viewModel.followingTabGoingItems) { item in
                            goingPlanCard(item)
                        }
                    }
                }

                sectionTitle("Saved Venues")

                if viewModel.followingTabSavedVenues.isEmpty {
                    emptyCard(
                        icon: "heart",
                        title: "No saved venues yet",
                        subtitle: "Tap the heart on a venue to save it."
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
            .padding(.horizontal)
            .padding(.bottom, 110)
        }
        .refreshable {
            await viewModel.refreshFollowingTabDataGlobally()
        }
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

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .fontWeight(.bold)
            .foregroundStyle(.primary)
    }

    private func emptyCard(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.largeTitle)
                .foregroundStyle(.secondary)

            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)

            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
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
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
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
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
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
