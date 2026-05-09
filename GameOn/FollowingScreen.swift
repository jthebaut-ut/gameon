import SwiftUI

struct FollowingScreen: View {
    @ObservedObject var viewModel: MapViewModel

    @State private var favoriteActionBanner: String?

    /// Venue events the user marked "Interested" from Following without a Supabase row (table has no status column).
    @AppStorage("gameon.following.interestedOnlyVenueEventIDs") private var interestedOnlyEncoded: String = ""

    var favoriteVenues: [BarVenue] {
        guard viewModel.isLoggedIn else { return [] }
        return viewModel.bars.filter {
            viewModel.favoriteVenueIDs.contains($0.id)
        }
    }

    /// Games tracked on Following: Supabase "Going" plus locally stored "Interested" rows.
    private var attendancePlans: [FollowingAttendancePlan] {
        guard viewModel.isLoggedIn else { return [] }
        let localInterested = decodeInterestedOnlyUUIDs(from: interestedOnlyEncoded)
        var plans: [FollowingAttendancePlan] = []

        for row in viewModel.venueEventRows {
            guard let id = row.id, let title = row.event_title else { continue }

            let serverGoing = viewModel.isInterestedInVenueEvent(id)
            let localInterestedOnly = localInterested.contains(id)
            guard serverGoing || localInterestedOnly else { continue }

            guard let bar = barMatchingVenueEvent(row: row, gameTitle: title) else { continue }

            let count = viewModel.venueEventInterestCounts[id] ?? 0
            plans.append(
                FollowingAttendancePlan(
                    id: id,
                    bar: bar,
                    gameTitle: title,
                    date: row.event_date ?? "Date TBD",
                    time: row.event_time ?? "Time TBD",
                    attendeeCount: count,
                    isServerGoing: serverGoing
                )
            )
        }

        return plans
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.94)
                .ignoresSafeArea()

            if viewModel.isLoggedIn {
                loggedInContent
            } else {
                loggedOutContent
            }
        }
        .onChange(of: viewModel.isLoggedIn) { _, isLoggedIn in
            if isLoggedIn {
                Task { await reloadFollowingDataForCurrentUser() }
            } else {
                clearFollowingUserSpecificState()
                interestedOnlyEncoded = ""
            }
        }
    }

    // MARK: - Logged out

    private var loggedOutContent: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 24)

            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 52))
                .foregroundStyle(.white.opacity(0.85))
                .symbolRenderingMode(.hierarchical)

            Text("Sign in required")
                .font(.largeTitle)
                .fontWeight(.bold)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            Text("Sign in to save venues and track games you plan to attend.")
                .font(.body)
                .foregroundStyle(.white.opacity(0.72))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

            Button {
                viewModel.discoverNavigateToAccountForUserAuth = true
            } label: {
                Text("Sign in or create account")
                    .font(.headline)
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.white)
                    .foregroundStyle(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
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
                    .foregroundStyle(.white)
                    .padding(.top, 22)

                Text("Your saved venues and games you plan to attend.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))

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

                if attendancePlans.isEmpty {
                    emptyCard(
                        icon: "person.badge.plus",
                        title: "No plans yet",
                        subtitle: "Tap “I’m going” on a venue event to add it here."
                    )
                } else {
                    VStack(spacing: 12) {
                        ForEach(attendancePlans) { plan in
                            goingPlanCard(plan)
                        }
                    }
                }

                sectionTitle("Saved Venues")

                if favoriteVenues.isEmpty {
                    emptyCard(
                        icon: "heart",
                        title: "No saved venues yet",
                        subtitle: "Tap the heart on a venue to save it."
                    )
                } else {
                    VStack(spacing: 12) {
                        ForEach(favoriteVenues) { bar in
                            venueCard(bar)
                        }
                    }
                    .animation(.spring(response: 0.36, dampingFraction: 0.86), value: viewModel.favoriteVenueIDs)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 110)
        }
    }

    // MARK: - Session / cache (Following tab only)

    private func clearFollowingUserSpecificState() {
        viewModel.favoriteVenueIDs = []
        viewModel.venueEventInterestIDs = []
        viewModel.interestedVenueEventKeys = []
    }

    private func reloadFollowingDataForCurrentUser() async {
        await viewModel.loadFavoriteVenuesFromSupabase()
        await viewModel.loadVisibleVenueEventInterests()
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
    private func applyAttendance(_ plan: FollowingAttendancePlan, target: FollowingAttendanceTarget) async {
        guard viewModel.isLoggedIn else { return }

        let localInterested = decodeInterestedOnlyUUIDs(from: interestedOnlyEncoded)

        switch target {
        case .going:
            if plan.isServerGoing, !localInterested.contains(plan.id) { return }
            setInterestedOnlyLocally(plan.id, false)
            await viewModel.markInterestedInVenueEvent(venueEventID: plan.id)
        case .interested:
            if !plan.isServerGoing, localInterested.contains(plan.id) { return }
            await viewModel.removeInterestInVenueEvent(venueEventID: plan.id)
            setInterestedOnlyLocally(plan.id, true)
        case .notGoing:
            if !plan.isServerGoing, !localInterested.contains(plan.id) { return }
            await viewModel.removeInterestInVenueEvent(venueEventID: plan.id)
            setInterestedOnlyLocally(plan.id, false)
        }

        await viewModel.loadVisibleVenueEventInterests()
        await viewModel.loadGoingUserProfiles(for: plan.id)
    }

    // MARK: - Shared UI pieces

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .fontWeight(.bold)
            .foregroundStyle(.white)
    }

    private func emptyCard(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.largeTitle)
                .foregroundStyle(.white.opacity(0.7))

            Text(title)
                .font(.headline)
                .foregroundStyle(.white)

            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color.white.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private func goingPlanCard(_ plan: FollowingAttendancePlan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Text(plan.gameTitle)
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 8)

                attendanceMenu(plan: plan)
            }

            if !plan.date.isEmpty || !plan.time.isEmpty {
                Text([plan.date, plan.time].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(plan.bar.name)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)

            Text(plan.bar.address)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                GoingAvatarStack(profiles: viewModel.goingProfiles(for: plan.id))
                Label("\(plan.attendeeCount) people interested / going", systemImage: "person.3.fill")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundStyle(.green)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .task(id: plan.id) {
            guard viewModel.isLoggedIn else { return }
            await viewModel.loadGoingUserProfiles(for: plan.id)
        }
    }

    @ViewBuilder
    private func attendanceMenu(plan: FollowingAttendancePlan) -> some View {
        if viewModel.isLoggedIn {
            Menu {
                Button {
                    Task { await applyAttendance(plan, target: .going) }
                } label: {
                    Label("Going ✅", systemImage: "checkmark.circle.fill")
                }

                Button {
                    Task { await applyAttendance(plan, target: .interested) }
                } label: {
                    Label("Interested 👀", systemImage: "eye")
                }

                Button(role: .destructive) {
                    Task { await applyAttendance(plan, target: .notGoing) }
                } label: {
                    Label("Not going ❌", systemImage: "xmark.circle")
                }
            } label: {
                attendancePill(plan: plan)
            }
            .buttonStyle(.plain)
        } else {
            attendancePill(plan: plan)
                .opacity(0.45)
        }
    }

    private func attendancePill(plan: FollowingAttendancePlan) -> some View {
        let isGoing = plan.isServerGoing
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
                    viewModel.openDirections(to: bar)
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
        .background(Color.white.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private func toggleSavedVenueHeart(bar: BarVenue, currentlySaved: Bool) async {
        guard viewModel.isLoggedIn else { return }
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

    // MARK: - Venue row matching (mirrors ``MapViewModel/interestedPlans()``)

    private func barMatchingVenueEvent(row: VenueEventRow, gameTitle: String) -> BarVenue? {
        viewModel.bars.first { bar in
            if let venueName = row.venue_name, bar.name == venueName {
                return true
            }
            if bar.games.contains(gameTitle) {
                return true
            }
            return false
        }
    }
}

// MARK: - Following attendance models (file-local)

private struct FollowingAttendancePlan: Identifiable {
    let id: UUID
    let bar: BarVenue
    let gameTitle: String
    let date: String
    let time: String
    let attendeeCount: Int
    /// `true` when the signed-in user has a `venue_event_interests` row (Going). `false` when only locally tracked as Interested.
    let isServerGoing: Bool
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
