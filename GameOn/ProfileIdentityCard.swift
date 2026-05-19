import Photos
import PhotosUI
import SwiftUI
import CoreLocation

/// Unified Account-tab “Profile & Identity” card: compact profile, reputation, and favorite teams in one surface.
struct ProfileIdentityCard: View {
    @ObservedObject var viewModel: MapViewModel
    @ObservedObject private var fanUpdatesStore: FanUpdatesRealtimeStore
    @EnvironmentObject private var chatViewModel: ChatViewModel
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focusedIdentityField: IdentityField?

    @AppStorage(FavoriteTeamsStore.appStorageKey) private var favoriteTeamIDsRaw: String = ""
    @State private var showFavoriteTeamsPicker = false
    @State private var showHandleSetup = false
    @State private var showIdentityEditor = false
    @State private var selectedAvatarItem: PhotosPickerItem?
    @State private var editedDisplayName = ""
    @State private var editedUsername = ""
    @State private var editedBio = ""
    @State private var identityMessage = ""
    @State private var handleStatusMessage = ""
    @State private var handleStatusIsPositive = false
    @State private var availabilityTask: Task<Void, Never>?
    @State private var isSavingIdentity = false
    @State private var isUploadingAvatar = false
    @State private var incomingPropsFans: [ProfilePropUserPreview] = []
    @State private var isLoadingIncomingProps = false
    @State private var incomingPropsMessage: String?
    @State private var showFanPropsHighlightsSheet = false

    private static let bioCharacterLimit = 160
    private static let incomingPropsHighlightsLimit = 24

    private let profilePropsService = ProfilePropsService()

    private enum IdentityField: Hashable {
        case displayName
        case username
        case bio
    }

    init(viewModel: MapViewModel) {
        _viewModel = ObservedObject(wrappedValue: viewModel)
        _fanUpdatesStore = ObservedObject(wrappedValue: viewModel.fanUpdatesStore)
    }

    private var selectedTeams: [FavoriteTeam] {
        FavoriteTeamsStore.resolvedTeams(from: favoriteTeamIDsRaw)
    }

    private var selectedIDSet: Set<String> {
        Set(FavoriteTeamsStore.decodeIDs(from: favoriteTeamIDsRaw))
    }

    private var displayName: String {
        let current = viewModel.currentUserDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty { return current }
        let email = viewModel.currentUserEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let local = email.split(separator: "@").first.map(String.init) ?? ""
        guard !local.isEmpty else { return "Fan" }
        return local.prefix(1).uppercased() + local.dropFirst()
    }

    /// Persisted @handle, or temporary email-prefix fallback only (never saved as username).
    private var handleLine: String {
        viewModel.currentUserPublicHandleLine
    }

    private var bioLine: String {
        viewModel.currentUserBio.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var fanXP: FanXPState {
        viewModel.currentUserFanXP
    }

    private var reputation: FanReputationProfile {
        FanReputationEngine.evaluate(
            FanReputationSignals(
                fanXP: fanXP,
                favoriteTeams: selectedTeams,
                localContext: localContext,
                savedVenueCount: savedVenueCount,
                venuePlanCount: viewModel.followingTabGoingItems.count,
                pickupHostedCount: viewModel.myPickupGamesForSettings.count + viewModel.myRemovedPickupGamesForSettings.count,
                pickupJoinedCount: viewModel.myPickupGameJoinRequestCards.count,
                organizerStats: currentOrganizerStats,
                commentCount: locallyLoadedCommentCount,
                reactionCount: locallyLoadedReactionCount
            ),
            shouldLog: false
        )
    }

    private var currentOrganizerStats: PickupCreatorPublicRatingStats? {
        guard let uid = viewModel.currentUserAuthId else { return nil }
        return viewModel.pickupCreatorTrustStats(for: uid)
    }

    private var localContext: String? {
        FanReputationEngine.localContext(
            latitude: viewModel.currentUserLocation?.latitude,
            longitude: viewModel.currentUserLocation?.longitude
        )
    }

    private var locallyLoadedCommentCount: Int {
        fanUpdatesStore.venueEventComments.values.reduce(0) { $0 + $1.count }
    }

    private var locallyLoadedReactionCount: Int {
        fanUpdatesStore.venueEventVibeCounts.values.reduce(0) { total, counts in
            total + counts.values.reduce(0, +)
        }
    }

    private var savedVenueCount: Int {
        max(viewModel.favoriteVenueIDs.count, viewModel.followingTabSavedVenues.count)
    }

    private func logFanUpdatesStoreMigrationDebug() {
#if DEBUG
        print("[FanUpdatesStoreMigrationDebug] ProfileIdentityReadsStore=true")
#endif
    }

    private var canShowOwnerFanPropsHighlights: Bool {
        viewModel.isLoggedIn && viewModel.currentUserAuthId != nil
    }

    var body: some View {
        let _: Void = logFanUpdatesStoreMigrationDebug()

        VStack(alignment: .leading, spacing: 14) {
            if viewModel.needsFanHandleSelection && !viewModel.needsBlockingFanIdentitySetup {
                handlePromptBanner
            }

            heroBlock

            if canShowOwnerFanPropsHighlights {
                fanPropsHighlightsSection
                    .padding(.horizontal, 16)
            }

            fanReputationSection
                .padding(.horizontal, 16)

            favoriteTeamsSection
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
        }
        .background(cardShellBackground)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(cardBorder)
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.07), radius: 22, y: 12)
        .shadow(color: FGColor.accentBlue.opacity(colorScheme == .dark ? 0.035 : 0.055), radius: 18, y: 3)
        .onAppear {
#if DEBUG
            print("[ProfileIdentityCardDebug] layout=modern_light_social_profile")
#endif
            FanReputationEngine.log(reputation)
        }
        .sheet(isPresented: $showHandleSetup) {
            FanGeoIdentitySetupView(viewModel: viewModel, mode: .handleOnly)
        }
        .sheet(isPresented: $showIdentityEditor) {
            identityEditorSheet
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showFavoriteTeamsPicker) {
            FavoriteTeamsPickerSheet(
                selectedIDs: Binding(
                    get: { selectedIDSet },
                    set: { newSet in
                        let sorted = Array(newSet).sorted()
                        favoriteTeamIDsRaw = FavoriteTeamsStore.encodeIDs(sorted)
                        Task {
                            await viewModel.syncFavoriteTeamsToSupabase(teamIDs: sorted)
                        }
                    }
                )
            )
        }
        .sheet(isPresented: $showFanPropsHighlightsSheet) {
            fanPropsHighlightsSheet
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .task(id: viewModel.currentUserAuthId) {
            await loadIncomingPropsHighlights()
        }
        .onChange(of: selectedAvatarItem) { _, item in
            guard let item else { return }
            Task { await replaceAvatar(with: item) }
        }
        .onChange(of: editedUsername) { _, _ in
            scheduleHandleAvailabilityCheck()
        }
        .onChange(of: editedBio) { _, newValue in
            let limited = limitedBio(newValue)
            if limited != newValue {
                editedBio = limited
            }
        }
    }

    // MARK: - Shell

    private var cardShellBackground: some View {
        ZStack {
            Color(.secondarySystemGroupedBackground)
            LinearGradient(
                colors: [
                    Color.white.opacity(colorScheme == .dark ? 0.08 : 0.96),
                    Color(red: 0.94, green: 0.98, blue: 1.0).opacity(colorScheme == .dark ? 0.05 : 0.72),
                    FGColor.accentGreen.opacity(colorScheme == .dark ? 0.035 : 0.055)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [
                        Color.white.opacity(colorScheme == .dark ? 0.10 : 0.92),
                        FGColor.accentBlue.opacity(colorScheme == .dark ? 0.08 : 0.12),
                        Color.black.opacity(colorScheme == .dark ? 0.02 : 0.055)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 0.75
            )
    }

    // MARK: - Fan Props highlights

    private var fanPropsHighlightsSection: some View {
        Button {
            guard !incomingPropsFans.isEmpty else { return }
            showFanPropsHighlightsSheet = true
        } label: {
            HStack(spacing: 11) {
                fanPropsAvatarStack

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text("Fan Props")
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(FGColor.mutedText(colorScheme))
                            .textCase(.uppercase)
                            .tracking(0.7)

                        Image(systemName: "sparkles")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(FGColor.accentGreen)
                    }

                    Text(fanPropsHighlightsCopy)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(incomingPropsFans.isEmpty ? FGColor.secondaryText(colorScheme) : FGColor.primaryText(colorScheme))
                        .lineLimit(1)

                    Text(fanPropsHighlightsSubcopy)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if isLoadingIncomingProps {
                    ProgressView()
                        .controlSize(.small)
                        .tint(FGColor.accentGreen)
                } else if !incomingPropsFans.isEmpty {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(FGColor.mutedText(colorScheme).opacity(0.72))
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(colorScheme == .dark ? 0.07 : 0.96),
                                FGColor.accentGreen.opacity(colorScheme == .dark ? 0.10 : 0.09),
                                FGColor.accentBlue.opacity(colorScheme == .dark ? 0.05 : 0.055)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        FGColor.accentGreen.opacity(colorScheme == .dark ? 0.18 : 0.16),
                                        Color.white.opacity(colorScheme == .dark ? 0.06 : 0.78)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 0.75
                            )
                    }
            }
        }
        .buttonStyle(.plain)
        .disabled(incomingPropsFans.isEmpty)
        .accessibilityLabel(fanPropsHighlightsAccessibilityLabel)
    }

    private var fanPropsAvatarStack: some View {
        ZStack {
            if incomingPropsFans.isEmpty {
                Circle()
                    .fill(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.14 : 0.10))
                    .frame(width: 42, height: 42)
                    .overlay {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(FGColor.accentBlue)
                    }
                    .overlay {
                        Circle()
                            .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.10 : 0.9), lineWidth: 1)
                    }
            } else {
                let visibleFans = Array(incomingPropsFans.prefix(4))
                ZStack(alignment: .leading) {
                    ForEach(Array(visibleFans.enumerated()), id: \.element.id) { index, fan in
                        fanPropsAvatar(fan)
                            .offset(x: CGFloat(index) * 18)
                            .zIndex(Double(visibleFans.count - index))
                    }
                }
                .frame(width: CGFloat(visibleFans.count - 1) * 18 + 34, height: 36, alignment: .leading)
            }
        }
        .frame(width: 88, alignment: .leading)
    }

    private func fanPropsAvatar(_ fan: ProfilePropUserPreview) -> some View {
        UserAvatarView(
            avatarThumbnailURL: fan.avatarThumbnailURL,
            avatarURL: fan.avatarURL ?? "",
            avatarDisplayRefreshToken: UUID(),
            displayName: fan.displayName,
            email: "",
            size: 34,
            fallbackStyle: .lightOnWhiteChrome,
            imagePlaceholderTint: FGColor.accentBlue
        )
        .overlay {
            Circle()
                .strokeBorder(Color(.secondarySystemGroupedBackground), lineWidth: 2)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.22 : 0.12), radius: 4, y: 2)
    }

    private var fanPropsHighlightsCopy: String {
        if isLoadingIncomingProps && incomingPropsFans.isEmpty {
            return "Loading Fan Props..."
        }
        guard !incomingPropsFans.isEmpty else { return "No Fan Props yet" }
        return incomingPropsFans.count == 1 ? "1 fan gave you props" : "\(incomingPropsFans.count) fans gave you props"
    }

    private var fanPropsHighlightsSubcopy: String {
        if let incomingPropsMessage, !incomingPropsMessage.isEmpty {
            return incomingPropsMessage
        }
        return incomingPropsFans.isEmpty ? "Fans can show love from your public profile" : "Recent fans who showed love"
    }

    private var fanPropsHighlightsAccessibilityLabel: String {
        incomingPropsFans.isEmpty ? "Fan Props, no Fan Props yet" : "Fan Props, \(fanPropsHighlightsCopy)"
    }

    private var fanPropsHighlightsSheet: some View {
        NavigationStack {
            List {
                if incomingPropsFans.isEmpty {
                    Text("No Fan Props yet")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                } else {
                    ForEach(incomingPropsFans) { fan in
                        HStack(spacing: 10) {
                            UserAvatarView(
                                avatarThumbnailURL: fan.avatarThumbnailURL,
                                avatarURL: fan.avatarURL ?? "",
                                avatarDisplayRefreshToken: UUID(),
                                displayName: fan.displayName,
                                email: "",
                                size: 38,
                                fallbackStyle: .lightOnWhiteChrome
                            )

                            VStack(alignment: .leading, spacing: 2) {
                                Text(fan.displayName)
                                    .font(.system(size: 14, weight: .bold, design: .rounded))
                                    .foregroundStyle(FGColor.primaryText(colorScheme))
                                    .lineLimit(1)

                                if !fan.publicHandleLine.isEmpty {
                                    Text(fan.publicHandleLine)
                                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                                        .lineLimit(1)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("Fan Props")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showFanPropsHighlightsSheet = false }
                }
            }
        }
    }

    private func loadIncomingPropsHighlights() async {
        guard canShowOwnerFanPropsHighlights else {
            await MainActor.run {
                incomingPropsFans = []
                incomingPropsMessage = nil
                isLoadingIncomingProps = false
            }
            return
        }

        await MainActor.run {
            isLoadingIncomingProps = true
            incomingPropsMessage = nil
        }

        do {
            let fans = try await profilePropsService.fetchMyIncomingProps(limit: Self.incomingPropsHighlightsLimit)
            await MainActor.run {
                incomingPropsFans = fans
                incomingPropsMessage = nil
                isLoadingIncomingProps = false
            }
        } catch {
            await MainActor.run {
                incomingPropsFans = []
                incomingPropsMessage = "Couldn't load Fan Props"
                isLoadingIncomingProps = false
            }
        }
    }

    // MARK: - Handle prompt

    private var handlePromptBanner: some View {
        Button {
            showHandleSetup = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "at")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(FGColor.accentGreen)
                Text("Choose your @handle for friend search")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(FGColor.accentGreen.opacity(0.12))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    // MARK: - Hero (compact header + stats)

    private var heroBlock: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerRow
                .padding(.horizontal, 16)
                .padding(.top, 16)

            statsRow
                .padding(.horizontal, 16)
        }
    }

    private var headerRow: some View {
        HStack(alignment: .top, spacing: 15) {
            PhotosPicker(selection: $selectedAvatarItem, matching: .images) {
                avatarStack
            }
            .disabled(isUploadingAvatar || isSavingIdentity)
            .buttonStyle(.plain)
            .accessibilityLabel("Update profile photo")

            VStack(alignment: .leading, spacing: 9) {
                Button {
                    presentIdentityEditor(focusedField: .displayName)
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Text(displayName)
                                .font(.system(size: 24, weight: .bold, design: .rounded))
                                .foregroundStyle(FGColor.primaryText(colorScheme))
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)

                            if reputation.privileges.isVerifiedOrganizer {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(FGColor.accentBlue)
                            }
                        }

                        Text(handleLine)
                            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit display name and handle")

                Button {
                    presentIdentityEditor(focusedField: .bio)
                } label: {
                    Text(bioLine.isEmpty ? "Add a short bio so fans know your vibe." : bioLine)
                        .font(.system(size: 12.5, weight: .medium, design: .rounded))
                        .foregroundStyle(bioLine.isEmpty ? FGColor.mutedText(colorScheme) : FGColor.primaryText(colorScheme).opacity(0.82))
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(bioLine.isEmpty ? "Add bio" : "Edit bio")

                HStack(spacing: 7) {
                    reputationPill

                    if !identityMessage.isEmpty {
                        Text(identityMessage)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(identityMessage.contains("updated") || identityMessage == "Saved." ? FGColor.accentGreen : FGColor.secondaryText(colorScheme))
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 0)
        }
    }

    private var reputationPill: some View {
        HStack(spacing: 5) {
            Image(systemName: reputation.privileges.isVerifiedOrganizer ? "checkmark.seal.fill" : "bolt.heart.fill")
                .font(.system(size: 9.5, weight: .bold))
            Text(reputation.title.uppercased())
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .tracking(0.55)
                .lineLimit(1)
        }
        .foregroundStyle(FGColor.accentGreen)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.16 : 0.11))
        .clipShape(Capsule())
    }

    private var avatarStack: some View {
        ZStack(alignment: .bottomTrailing) {
            UserAvatarView(
                avatarThumbnailURL: viewModel.currentUserAvatarThumbnailURL,
                avatarURL: viewModel.currentUserAvatarURL,
                avatarDisplayRefreshToken: viewModel.currentUserAvatarDisplayRefreshToken,
                displayName: displayName,
                email: viewModel.currentUserEmail,
                size: 94,
                fallbackStyle: .lightOnWhiteChrome,
                imagePlaceholderTint: FGColor.accentBlue
            )
            .overlay {
                Circle()
                    .strokeBorder(
                        AngularGradient(
                            colors: [
                                FGColor.accentBlue,
                                FGColor.accentGreen,
                                Color(red: 0.98, green: 0.67, blue: 0.33),
                                FGColor.accentBlue
                            ],
                            center: .center
                        ),
                        lineWidth: 3
                    )
            }
            .padding(3)
            .background(Circle().fill(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.96)))
            .shadow(color: FGColor.accentBlue.opacity(colorScheme == .dark ? 0.18 : 0.16), radius: 12, y: 5)

            Circle()
                .fill(Color(.secondarySystemGroupedBackground))
                .frame(width: 27, height: 27)
                .overlay {
                    if isUploadingAvatar {
                        ProgressView()
                            .controlSize(.small)
                            .tint(FGColor.accentGreen)
                    } else {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(FGColor.accentGreen)
                    }
                }
                .overlay {
                    Circle()
                        .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.14 : 0.95), lineWidth: 1.5)
                }
                .offset(x: 2, y: 2)
        }
    }

    // MARK: - Inline identity editing

    private var identityEditorSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .center, spacing: 12) {
                        PhotosPicker(selection: $selectedAvatarItem, matching: .images) {
                            avatarStack
                        }
                        .disabled(isUploadingAvatar || isSavingIdentity)
                        .buttonStyle(.plain)

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Edit your profile")
                                .font(.system(size: 19, weight: .bold, design: .rounded))
                                .foregroundStyle(FGColor.primaryText(colorScheme))
                            Text("Your public fan identity")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                        }
                    }

                    identityFieldCard(title: "Display name", subtitle: "Shown on your profile and social activity.") {
                        TextField("Display name", text: $editedDisplayName)
                            .textInputAutocapitalization(.words)
                            .disableAutocorrection(true)
                            .focused($focusedIdentityField, equals: .displayName)
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .profileIdentityInputStyle(colorScheme: colorScheme)
                    }

                    identityFieldCard(title: "@handle", subtitle: "Unique username for friend search.") {
                        HStack(spacing: 4) {
                            Text("@")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                            TextField("handle", text: $editedUsername)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($focusedIdentityField, equals: .username)
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                        }
                        .profileIdentityInputStyle(colorScheme: colorScheme)

                        if !handleStatusMessage.isEmpty {
                            Text(handleStatusMessage)
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(handleStatusIsPositive ? FGColor.accentGreen : FGColor.secondaryText(colorScheme))
                        }
                    }

                    identityFieldCard(title: "Bio", subtitle: "A short line about your fan energy.") {
                        TextEditor(text: $editedBio)
                            .focused($focusedIdentityField, equals: .bio)
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .frame(minHeight: 82)
                            .scrollContentBackground(.hidden)
                            .profileIdentityInputStyle(colorScheme: colorScheme)
                            .overlay(alignment: .topLeading) {
                                if editedBio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text("Add a short bio")
                                        .font(.system(size: 15, weight: .medium, design: .rounded))
                                        .foregroundStyle(FGColor.secondaryText(colorScheme).opacity(0.55))
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 12)
                                        .allowsHitTesting(false)
                                }
                            }

                        Text("\(editedBio.count)/\(Self.bioCharacterLimit)")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }

                    if !identityMessage.isEmpty {
                        Text(identityMessage)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(identityMessage.contains("updated") || identityMessage == "Saved." ? FGColor.accentGreen : FGColor.secondaryText(colorScheme))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 28)
            }
            .fanGeoScreenBackground()
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { showIdentityEditor = false }
                        .disabled(isSavingIdentity || isUploadingAvatar)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSavingIdentity ? "Saving..." : "Save") {
                        Task { await saveIdentity() }
                    }
                    .disabled(isSavingIdentity || isUploadingAvatar)
                }
            }
            .onAppear {
                resetIdentityDraft()
            }
        }
    }

    private func identityFieldCard<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                Text(subtitle)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
            }

            content()
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(FGColor.cardBackground(colorScheme).opacity(colorScheme == .dark ? 0.86 : 0.98))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
                }
        }
    }

    private func presentIdentityEditor(focusedField: IdentityField) {
        resetIdentityDraft()
        showIdentityEditor = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            self.focusedIdentityField = focusedField
        }
    }

    private func resetIdentityDraft() {
        editedDisplayName = displayName
        editedUsername = viewModel.currentUserUsername
        editedBio = limitedBio(viewModel.currentUserBio)
        handleStatusMessage = ""
        handleStatusIsPositive = false
    }

    private func limitedBio(_ raw: String) -> String {
        String(raw.prefix(Self.bioCharacterLimit))
    }

    private func profilePhotoPickFailureHint() -> String {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .denied, .restricted:
            return "Photo access is off. Turn it on in Settings > Privacy & Security > Photos to upload a profile picture."
        case .limited:
            return "Couldn’t use that photo. Try another image, or allow more photos for FanGeo in Settings."
        default:
            return "Unable to read that photo. Try a different image or check your connection."
        }
    }

    private func scheduleHandleAvailabilityCheck() {
        availabilityTask?.cancel()
        handleStatusMessage = ""
        handleStatusIsPositive = false

        let raw = editedUsername
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }
        if let issue = FanGeoHandleRules.validate(raw) {
            handleStatusMessage = FanGeoHandleRules.validationMessage(for: issue)
            return
        }

        availabilityTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            guard let available = await viewModel.checkUsernameAvailable(raw) else { return }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                if available {
                    handleStatusMessage = "Handle available."
                    handleStatusIsPositive = true
                } else {
                    handleStatusMessage = "That handle is already taken."
                    handleStatusIsPositive = false
                }
            }
        }
    }

    private func saveIdentity() async {
        guard viewModel.isLoggedIn else {
            await MainActor.run { identityMessage = "Please sign in to edit your profile." }
            return
        }

        await MainActor.run { isSavingIdentity = true }
        defer { Task { @MainActor in isSavingIdentity = false } }

        let trimmed = editedDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextName = trimmed.isEmpty ? displayName : trimmed
        if ModerationService.containsProfanity(nextName) {
            await MainActor.run { identityMessage = ModerationService.profanityRejectionUserMessage() }
            return
        }
        if let issue = FanGeoHandleRules.validate(editedUsername) {
            await MainActor.run { identityMessage = FanGeoHandleRules.validationMessage(for: issue) }
            return
        }

        let nextBio = limitedBio(editedBio)
        if let err = await viewModel.saveUserProfile(
            displayName: nextName,
            avatarURL: viewModel.currentUserAvatarURL,
            avatarThumbnailURL: viewModel.currentUserAvatarThumbnailURL,
            username: editedUsername,
            bio: nextBio
        ) {
            await MainActor.run { identityMessage = err }
            return
        }

        await MainActor.run {
            identityMessage = "Saved."
            showIdentityEditor = false
        }
    }

    private func replaceAvatar(with item: PhotosPickerItem) async {
        guard viewModel.isLoggedIn else {
            await MainActor.run { identityMessage = "Please sign in to update your avatar." }
            return
        }

        await MainActor.run {
            isUploadingAvatar = true
            identityMessage = "Uploading avatar..."
        }
        defer { Task { @MainActor in isUploadingAvatar = false } }

        guard let data = try? await item.loadTransferable(type: Data.self) else {
            await MainActor.run { identityMessage = profilePhotoPickFailureHint() }
            return
        }
        guard let urls = await viewModel.uploadUserAvatar(data: data, fileName: "avatar.jpg") else {
            await MainActor.run { identityMessage = "Unable to upload avatar." }
            return
        }

        let trimmed = editedDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextName = trimmed.isEmpty ? displayName : trimmed
        if ModerationService.containsProfanity(nextName) {
            await MainActor.run { identityMessage = ModerationService.profanityRejectionUserMessage() }
            return
        }
        if let err = await viewModel.saveUserProfile(
            displayName: nextName,
            avatarURL: urls.fullURL,
            avatarThumbnailURL: urls.thumbnailURL
        ) {
            await MainActor.run { identityMessage = err }
            return
        }
        await MainActor.run { identityMessage = "Avatar updated." }
    }

    // MARK: - Stats

    private var statsRow: some View {
        HStack(spacing: 0) {
            statCell(value: gamesWatchedValue, label: "Plans")
            statDivider
            statCell(value: venuesVisitedValue, label: "Venues")
            statDivider
            statCell(value: teamsValue, label: "Teams")
            statDivider
            statCell(value: friendsValue, label: "Friends")
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(colorScheme == .dark ? 0.055 : 0.92))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.black.opacity(colorScheme == .dark ? 0.0 : 0.045), lineWidth: 0.75)
                }
        }
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.08 : 0.035), radius: 10, y: 5)
    }

    private var statDivider: some View {
        Rectangle()
            .fill(Color.black.opacity(colorScheme == .dark ? 0.14 : 0.06))
            .frame(width: 1)
            .padding(.vertical, 3)
    }

    private var gamesWatchedValue: String {
        let n = viewModel.followingTabGoingItems.count
        return n > 0 ? "\(n)" : "—"
    }

    private var venuesVisitedValue: String {
        let n = max(viewModel.favoriteVenueIDs.count, viewModel.followingTabSavedVenues.count)
        return n > 0 ? "\(n)" : "—"
    }

    private var teamsValue: String {
        let n = selectedTeams.count
        return n > 0 ? "\(n)" : "—"
    }

    private var friendsValue: String {
        let n = chatViewModel.friends.count
        return n > 0 ? "\(n)" : "—"
    }

    private func statCell(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(FGColor.primaryText(colorScheme))

            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(FGColor.mutedText(colorScheme))
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Reputation

    private var fanReputationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Reputation")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(FGColor.mutedText(colorScheme))
                .textCase(.uppercase)
                .tracking(0.7)

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: reputation.privileges.isVerifiedOrganizer ? "checkmark.seal.fill" : "person.2.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(FGColor.accentGreen)
                    .frame(width: 24, height: 24)
                    .background {
                        Circle()
                            .fill(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.16 : 0.11))
                    }

                VStack(alignment: .leading, spacing: 4) {
                    Text(reputation.title.uppercased())
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .tracking(0.6)

                    Text(reputation.subtitle)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))

                    Text(reputation.contextLine)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(FGColor.mutedText(colorScheme))

                    Text(reputation.whyEarnedText)
                        .font(.system(size: 10, weight: .regular, design: .rounded))
                        .foregroundStyle(FGColor.mutedText(colorScheme).opacity(0.86))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background {
                RoundedRectangle(cornerRadius: 19, style: .continuous)
                    .fill(Color.white.opacity(colorScheme == .dark ? 0.045 : 0.82))
                    .overlay {
                        RoundedRectangle(cornerRadius: 19, style: .continuous)
                            .strokeBorder(Color.black.opacity(colorScheme == .dark ? 0.0 : 0.04), lineWidth: 0.75)
                    }
            }
        }
    }

    // MARK: - Favorite teams

    private var favoriteTeamsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Favorite Teams")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                        .textCase(.uppercase)
                        .tracking(0.7)
                    Text(selectedTeams.isEmpty ? "Shape your fan identity" : "Show off your fan colors")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(FGColor.mutedText(colorScheme).opacity(0.82))
                }
                Spacer(minLength: 0)
                Button {
                    showFavoriteTeamsPicker = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "pencil")
                            .font(.system(size: 9, weight: .bold))
                        Text(selectedTeams.isEmpty ? "Add Teams" : "Edit Teams")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(FGColor.accentBlue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background {
                        Capsule()
                            .fill(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.14 : 0.10))
                    }
                }
                .buttonStyle(.plain)
            }

            if selectedTeams.isEmpty {
                addTeamSocialCard
            } else {
                favoriteTeamsCardRow
            }
        }
    }

    private var favoriteTeamsCardRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(selectedTeams) { team in
                    favoriteTeamSocialCard(team: team)
                }

                addTeamSocialCard
            }
            .padding(.vertical, 1)
        }
    }

    private func favoriteTeamSocialCard(team: FavoriteTeam) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                PremiumTeamIdentityOrb(team: team, diameter: 62)
                Spacer(minLength: 0)
                Image(systemName: "star.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.86))
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(team.name)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.75)

                Text(team.sport.chipTitle)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: 174, height: 148, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            team.badgeColor.opacity(0.96),
                            FGColor.accentBlue.opacity(0.84),
                            Color(red: 0.09, green: 0.12, blue: 0.18).opacity(0.92)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.34),
                                    Color.white.opacity(0.08)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                }
        }
        .shadow(color: team.badgeColor.opacity(colorScheme == .dark ? 0.18 : 0.16), radius: 14, y: 8)
    }

    private var addTeamSocialCard: some View {
        Button {
            showFavoriteTeamsPicker = true
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                ZStack {
                    Circle()
                        .fill(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.16 : 0.11))
                        .frame(width: 58, height: 58)
                    Image(systemName: "plus")
                        .font(.system(size: 21, weight: .bold))
                        .foregroundStyle(FGColor.accentBlue)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Add Team")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                    Text("Build your fan profile")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                }

                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(width: 148, height: 148, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.white.opacity(colorScheme == .dark ? 0.045 : 0.9))
                    .overlay {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        FGColor.accentBlue.opacity(colorScheme == .dark ? 0.22 : 0.16),
                                        Color.black.opacity(colorScheme == .dark ? 0.0 : 0.05)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add favorite team")
    }
}

private extension View {
    func profileIdentityInputStyle(colorScheme: ColorScheme) -> some View {
        self
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(FGColor.background(colorScheme).opacity(colorScheme == .dark ? 0.62 : 0.96))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
            }
    }
}

private struct PremiumTeamIdentityOrb: View {
    let team: FavoriteTeam
    let diameter: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.18))
                .frame(width: diameter, height: diameter)
                .overlay {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.34), lineWidth: 1)
                }

            Text(team.initials)
                .font(.system(size: max(10, diameter * 0.34), weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityLabel("\(team.name), \(team.sport.chipTitle)")
    }
}

