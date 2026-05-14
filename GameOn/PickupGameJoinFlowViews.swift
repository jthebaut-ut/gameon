import SwiftUI

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
    @State private var joinError: String?
    @State private var isCancellingRequest = false

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

    var body: some View {
        NavigationStack {
            Group {
                if let g = game {
                    detailContent(for: g)
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
            .task(id: gameId) {
                if let cid = game?.creator_user_id {
                    await viewModel.loadPickupCreatorDisplayNameIfNeeded(creatorUserId: cid)
                }
                await viewModel.loadMyLatestJoinRequestForPickupGame(pickupGameId: gameId)
            }
            .onChange(of: viewModel.pickupGamesForDiscoverMap.count) { _, _ in
                Task { await viewModel.loadMyLatestJoinRequestForPickupGame(pickupGameId: gameId) }
            }
        }
    }

    @ViewBuilder
    private func detailContent(for g: PickupGameRow) -> some View {
        let locationLine = [g.address, g.city, g.state]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        let creatorLabel = viewModel.pickupCreatorDisplayLabel(for: g.creator_user_id)
        let subtitleLine = "\(g.sport) • \(g.playEnvironmentEnum.shortLabel) • \(g.skillLevelEnum.displayTitle)"

        ScrollView {
            VStack(alignment: .leading, spacing: FGSpacing.md) {
                pickupHeroCard(
                    g: g,
                    locationLine: locationLine,
                    subtitleLine: subtitleLine
                )

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
                    pickupDetailTile(
                        title: "Organizer",
                        value: creatorLabel ?? "—",
                        systemImage: "person.crop.circle.fill"
                    )
                    pickupDetailTile(
                        title: "Play",
                        value: g.playEnvironmentEnum.displayTitle,
                        systemImage: "sportscourt.fill"
                    )
                }

                if let desc = g.description?.trimmingCharacters(in: .whitespacesAndNewlines), !desc.isEmpty {
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

    private func pickupHeroCard(g: PickupGameRow, locationLine: String, subtitleLine: String) -> some View {
        VStack(alignment: .leading, spacing: FGSpacing.sm) {
            FGStatusPill(title: "Pickup game", kind: .custom(tint: Color.orange))
            Text(g.title)
                .font(FGTypography.sectionTitle)
                .foregroundStyle(pickupDetailMainInk)

            Text(subtitleLine)
                .font(FGTypography.metadata.weight(.medium))
                .foregroundStyle(pickupDetailSubInk)

            if let start = PickupGameModels.parseSupabaseTimestamptz(g.game_start_at) {
                Text(start.formatted(date: .abbreviated, time: .shortened))
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
        .padding(FGSpacing.lg)
        .background { pickupGlassBackground(cornerRadius: FGRadius.large) }
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous))
        .overlay { pickupGlassStroke(cornerRadius: FGRadius.large) }
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
        } else if isCreator {
            EmptyView()
        } else if g.isPickupFullForDiscover {
            Text("No more players needed.")
                .font(FGTypography.caption.weight(.semibold))
                .foregroundStyle(pickupDetailSubInk)
                .padding(.top, FGSpacing.xs)
        } else {
            VStack(alignment: .leading, spacing: FGSpacing.sm) {
                if let req = myRequest {
                    labeledRow("Your request", req.statusDisplayTitle)
                    if req.status.lowercased() == "pending" {
                        Button(role: .cancel) {
                            Task { await cancelPendingRequest(req) }
                        } label: {
                            if isCancellingRequest {
                                ProgressView()
                            } else {
                                Text("Cancel request")
                            }
                        }
                        .buttonStyle(.bordered)
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
                }
            }
            .padding(.top, FGSpacing.sm)
        }
    }

    private func shouldShowRequestToJoin(for g: PickupGameRow) -> Bool {
        guard !g.isPickupFullForDiscover else { return false }
        guard let req = myRequest else { return true }
        let s = req.status.lowercased()
        return s == "rejected" || s == "cancelled"
    }

    private func cancelPendingRequest(_ req: PickupGameRequestRow) async {
        isCancellingRequest = true
        joinError = nil
        defer { isCancellingRequest = false }
        do {
            try await viewModel.cancelMyPickupJoinRequest(requestId: req.id, pickupGameId: gameId)
        } catch {
            joinError = error.localizedDescription
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
                    .disabled(isSubmitting)
                }
            }
        }
    }

    private func submit() async {
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
    @Environment(\.dismiss) private var dismiss

    @State private var rows: [PickupGameRequestRow] = []
    @State private var loadError: String?
    @State private var busyRequestId: UUID?

    var body: some View {
        NavigationStack {
            List {
                if let loadError, !loadError.isEmpty {
                    Text(loadError)
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.dangerRed)
                        .listRowBackground(FGColor.cardBackground(colorScheme))
                }
                if rows.isEmpty && loadError == nil {
                    Text("No requests yet.")
                        .font(FGTypography.body)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .listRowBackground(FGColor.cardBackground(colorScheme))
                }
                ForEach(rows) { req in
                    organizerRequestRow(req)
                        .listRowBackground(FGColor.cardBackground(colorScheme))
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
        }
    }

    @ViewBuilder
    private func organizerRequestRow(_ req: PickupGameRequestRow) -> some View {
        VStack(alignment: .leading, spacing: FGSpacing.sm) {
            Text(req.requesterNameForUI)
                .font(FGTypography.cardTitle)
                .foregroundStyle(FGColor.primaryText(colorScheme))
            Text(req.requesterSkillLevelEnum.displayTitle)
                .font(FGTypography.caption)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
            if let m = req.message?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty {
                Text(m)
                    .font(FGTypography.body)
                    .foregroundStyle(FGColor.primaryText(colorScheme))
            }
            Text(req.statusDisplayTitle)
                .font(FGTypography.caption.weight(.semibold))
                .foregroundStyle(FGColor.accentBlue)

            if req.status == "pending" {
                HStack(spacing: FGSpacing.sm) {
                    Button {
                        Task { await decide(req, approve: true) }
                    } label: {
                        if busyRequestId == req.id {
                            ProgressView()
                        } else {
                            Text("Approve")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(FGColor.accentGreen)
                    .disabled(busyRequestId != nil)

                    Button(role: .destructive) {
                        Task { await decide(req, approve: false) }
                    } label: {
                        Text("Reject")
                    }
                    .buttonStyle(.bordered)
                    .disabled(busyRequestId != nil)
                }
            }
        }
        .padding(.vertical, FGSpacing.xs)
    }

    private func reload() async {
        loadError = nil
        do {
            rows = try await viewModel.fetchOrganizerPickupRequests(pickupGameId: game.id)
        } catch {
            loadError = error.localizedDescription
            rows = []
        }
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
