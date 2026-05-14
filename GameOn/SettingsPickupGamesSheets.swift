import SwiftUI
import CoreLocation
import MapKit

enum PickupGameFormMode: Identifiable, Equatable {
    case add
    case edit(PickupGameRow)

    var id: String {
        switch self {
        case .add: return "pickup-form-add"
        case .edit(let row): return "pickup-form-\(row.id.uuidString)"
        }
    }
}

/// Settings → list of the signed-in fan’s pickup games (nested sheet for add / edit).
struct SettingsPickupGamesListSheet: View {
    @ObservedObject var viewModel: MapViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var formMode: PickupGameFormMode?
    @State private var deleteTarget: PickupGameRow?
    @State private var banner: String?
    @State private var organizerRequestsGame: PickupGameRow?

    var body: some View {
        List {
            if viewModel.myPickupGamesForSettings.isEmpty {
                Text("You have not posted a pickup game yet.")
                    .font(FGTypography.body)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .listRowBackground(FGColor.cardBackground(colorScheme))
            } else {
                ForEach(viewModel.myPickupGamesForSettings) { row in
                    HStack(alignment: .top, spacing: FGSpacing.sm) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(row.title)
                                .font(FGTypography.cardTitle)
                                .foregroundStyle(FGColor.primaryText(colorScheme))
                            HStack(spacing: 8) {
                                Text(row.sport)
                                    .font(FGTypography.caption)
                                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                                if let start = PickupGameModels.parseSupabaseTimestamptz(row.game_start_at) {
                                    Text(start.formatted(date: .abbreviated, time: .shortened))
                                        .font(FGTypography.caption)
                                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                                }
                            }
                            Text("\(row.playEnvironmentEnum.shortLabel) · \(row.skillLevelEnum.displayTitle) · \(row.entryFeeDisplayLine)")
                                .font(FGTypography.caption)
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                                .lineLimit(2)
                            Text("\(row.lookingForPlayersLine)\(row.maxPlayersChipTitle.map { " · \($0)" } ?? "")")
                                .font(FGTypography.caption)
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                            if !row.is_visible {
                                Text("Hidden from map")
                                    .font(FGTypography.caption.weight(.semibold))
                                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                            }
                            Text("\(viewModel.pickupOrganizerJoinStatsByGameId[row.id]?.pending ?? 0) pending · \(row.approvedJoinCount) approved · \(row.pickupOpenSlotsRemaining) spots open")
                                .font(FGTypography.caption)
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                            if row.isPickupFullForDiscover {
                                Text("Full — no more players needed")
                                    .font(FGTypography.caption.weight(.semibold))
                                    .foregroundStyle(FGColor.accentYellow)
                            }
                            Button {
                                organizerRequestsGame = row
                            } label: {
                                Text("Manage requests")
                                    .font(FGTypography.caption.weight(.semibold))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.bordered)
                            .tint(FGColor.accentBlue)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        VStack(spacing: 6) {
                            Button {
                                viewModel.logPickupGamesEditRequested(id: row.id)
                                formMode = .edit(row)
                            } label: {
                                Text("Edit")
                                    .font(FGTypography.caption.weight(.semibold))
                                    .foregroundStyle(FGColor.accentBlue)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: FGRadius.small, style: .continuous))
                            }
                            .buttonStyle(.plain)

                            Button {
                                deleteTarget = row
                            } label: {
                                Text("Delete")
                                    .font(FGTypography.caption.weight(.semibold))
                                    .foregroundStyle(FGColor.dangerRed)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: FGRadius.small, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .listRowBackground(FGColor.cardBackground(colorScheme))
                }
            }
        }
        .scrollContentBackground(.hidden)
        .fanGeoScreenBackground()
        .navigationTitle("My pickup games")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    formMode = .add
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .accessibilityLabel("Add pickup game")
            }
        }
        .task {
            await viewModel.loadMyPickupGamesForSettings()
        }
        .onAppear {
            if !viewModel.canFanUsePickupGamesUI {
                dismiss()
            }
        }
        .sheet(item: $formMode) { mode in
            NavigationStack {
                SettingsPickupGameFormView(viewModel: viewModel, mode: mode) {
                    formMode = nil
                    Task { await viewModel.loadMyPickupGamesForSettings() }
                }
            }
        }
        .sheet(item: $organizerRequestsGame, onDismiss: {
            Task { await viewModel.loadPendingPickupGameJoinRequestCountForCreator(resyncRealtimeSubscription: true) }
        }) { game in
            PickupOrganizerRequestsSheet(viewModel: viewModel, game: game)
        }
        .alert("Delete pickup game?", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )) {
            Button("Cancel", role: .cancel) { deleteTarget = nil }
            Button("Delete", role: .destructive) {
                guard let row = deleteTarget else { return }
                deleteTarget = nil
                Task { await performDelete(row) }
            }
        } message: {
            Text("This will remove it from your list, the Discover map, and the calendar.")
        }
        .overlay(alignment: .bottom) {
            if let banner, !banner.isEmpty {
                Text(banner)
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .padding(.horizontal, FGSpacing.md)
                    .padding(.vertical, FGSpacing.sm)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding()
            }
        }
    }

    private func performDelete(_ row: PickupGameRow) async {
        do {
            try await viewModel.softRemovePickupGame(id: row.id)
            banner = nil
            await viewModel.loadMyPickupGamesForSettings()
            await viewModel.refreshPickupGamesForDiscoverMap(force: true)
        } catch {
            banner = error.localizedDescription
        }
    }
}

private enum PickupCostKind: String, CaseIterable, Identifiable {
    case free
    case paid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .free: return "Free"
        case .paid: return "Paid"
        }
    }
}

/// Add or edit a pickup game (fan accounts only; caller gates).
struct SettingsPickupGameFormView: View {
    @ObservedObject var viewModel: MapViewModel
    let mode: PickupGameFormMode
    var onFinished: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var title: String = ""
    @State private var sport: String = "Soccer"
    @State private var gameDate: Date = Date()
    @State private var gameTime: Date = Date()
    @State private var address: String = ""
    @State private var city: String = ""
    @State private var state: String = ""
    @State private var description: String = ""
    @State private var playEnvironment: PickupPlayEnvironment = .either
    @State private var skillLevel: PickupGameSkillLevel = .casual
    @State private var participantPreference: PickupParticipantPreference = .everyone
    @State private var costKind: PickupCostKind = .free
    @State private var entryFeeText: String = ""
    @State private var playersNeeded: Int = 1
    @State private var useMaxPlayers: Bool = false
    @State private var maxPlayers: Int = 10
    @State private var isVisible: Bool = true
    @State private var cleanupHours: Int = 24
    @State private var isSaving = false
    @State private var errorText: String?
    @State private var showPickupMapLocationPicker = false
    @State private var coordinatesLockedFromMap = false
    @State private var mapPinnedCoordinate: CLLocationCoordinate2D?

    private var sportChoices: [String] {
        viewModel.sports.filter { $0 != "All" }
    }

    private var trimmedAddress: String {
        address.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedCity: String {
        city.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedState: String {
        state.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasCompleteTypedAddress: Bool {
        !trimmedAddress.isEmpty && !trimmedCity.isEmpty && !trimmedState.isEmpty
    }

    /// Post/Save enabled when address fields are complete (typed or filled from map picker).
    private var hasPlacedLocationForPostButton: Bool {
        hasCompleteTypedAddress
    }

    private var pickMapSeedCoordinate: CLLocationCoordinate2D {
        if case .edit(let row) = mode,
           let la = row.latitude,
           let lo = row.longitude {
            return CLLocationCoordinate2D(latitude: la, longitude: lo)
        }
        if let r = viewModel.cameraPosition.region {
            return r.center
        }
        return CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.00902)
    }

    private var addressBinding: Binding<String> {
        Binding(
            get: { address },
            set: { newValue in
                address = newValue
                coordinatesLockedFromMap = false
                mapPinnedCoordinate = nil
            }
        )
    }

    private var cityBinding: Binding<String> {
        Binding(
            get: { city },
            set: { newValue in
                city = newValue
                coordinatesLockedFromMap = false
                mapPinnedCoordinate = nil
            }
        )
    }

    private var stateBinding: Binding<String> {
        Binding(
            get: { state },
            set: { newValue in
                state = newValue
                coordinatesLockedFromMap = false
                mapPinnedCoordinate = nil
            }
        )
    }

    private var locationGuidanceFootnote: String? {
        if hasCompleteTypedAddress { return nil }
        if trimmedAddress.isEmpty && trimmedCity.isEmpty && trimmedState.isEmpty {
            return "Location missing"
        }
        return "Enter a complete street address, city, and state"
    }

    var body: some View {
        Form {
            if let errorText, !errorText.isEmpty {
                Section {
                    Text(errorText)
                        .font(FGTypography.caption)
                        .foregroundStyle(Color.red)
                }
            }

            Section("Game") {
                TextField("Title", text: $title)
                Picker("Sport", selection: $sport) {
                    ForEach(sportChoices, id: \.self) { s in
                        Text(s).tag(s)
                    }
                }
                DatePicker("Date", selection: $gameDate, displayedComponents: .date)
                DatePicker("Start time", selection: $gameTime, displayedComponents: .hourAndMinute)
                Stepper(value: $playersNeeded, in: 1...20) {
                    HStack {
                        Text("Players needed")
                        Spacer(minLength: 0)
                        Text(playersNeeded == 1 ? "1 player" : "\(playersNeeded) players")
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    }
                }
                Toggle("Set max players (capacity)", isOn: $useMaxPlayers)
                if useMaxPlayers {
                    Stepper(value: $maxPlayers, in: 1...100) {
                        HStack {
                            Text("Max players")
                            Spacer(minLength: 0)
                            Text("\(maxPlayers)")
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                        }
                    }
                }
            }

            Section("How you play") {
                Picker("Indoor / outdoor", selection: $playEnvironment) {
                    ForEach(PickupPlayEnvironment.allCases) { env in
                        Text(env.displayTitle).tag(env)
                    }
                }
                Picker("Skill level", selection: $skillLevel) {
                    ForEach(PickupGameSkillLevel.allCases) { level in
                        Text(level.displayTitle).tag(level)
                    }
                }
                Picker("Who’s welcome", selection: $participantPreference) {
                    ForEach(PickupParticipantPreference.allCases) { pref in
                        Text(pref.displayTitle).tag(pref)
                    }
                }
            }

            Section("Cost") {
                Picker("Entry", selection: $costKind) {
                    ForEach(PickupCostKind.allCases) { k in
                        Text(k.title).tag(k)
                    }
                }
                .pickerStyle(.segmented)
                if costKind == .paid {
                    TextField("Amount (USD)", text: $entryFeeText)
                        .keyboardType(.decimalPad)
                    Text("Paid games require an entry amount greater than zero.")
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }
            }

            Section("Location") {
                Button {
                    showPickupMapLocationPicker = true
                } label: {
                    Label("Pick location from map", systemImage: "mappin.and.ellipse")
                        .font(FGTypography.metadata.weight(.semibold))
                }

                TextField("Street address", text: addressBinding, axis: .vertical)
                    .lineLimit(1...3)
                TextField("City", text: cityBinding)
                TextField("State", text: stateBinding)

                if coordinatesLockedFromMap {
                    Text("Using exact coordinates from your map pin.")
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.accentBlue)
                }

                if let foot = locationGuidanceFootnote {
                    Text(foot)
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.accentYellow)
                }
            }

            Section("Details") {
                TextField("Description (optional)", text: $description, axis: .vertical)
                    .lineLimit(2...6)
                Toggle("Visible on Discover map", isOn: $isVisible)
                Picker("Cleanup window", selection: $cleanupHours) {
                    Text("24 hours after start").tag(24)
                    Text("48 hours after start").tag(48)
                    Text("72 hours after start").tag(72)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .fanGeoScreenBackground()
        .navigationTitle(mode == .add ? "Add pickup game" : "Edit pickup game")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { onFinished(); dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(mode == .add ? "Post" : "Save") {
                    Task { await save() }
                }
                .disabled(
                    isSaving
                        || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || !hasPlacedLocationForPostButton
                )
            }
        }
        .onAppear {
            applyModeToFields()
        }
        .onAppear {
            if !viewModel.canFanUsePickupGamesUI {
                onFinished()
                dismiss()
            }
        }
        .fullScreenCover(isPresented: $showPickupMapLocationPicker) {
            PickupGameMapLocationPickerSheet(
                viewModel: viewModel,
                initialCoordinate: pickMapSeedCoordinate,
                onCancel: { showPickupMapLocationPicker = false },
                onConfirm: { coord, street, cityName, stateAbbr in
                    if let s = street, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        address = s
                    }
                    if let c = cityName, !c.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        city = c
                    }
                    if let st = stateAbbr, !st.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        state = st
                    }
                    mapPinnedCoordinate = coord
                    coordinatesLockedFromMap = true
                    showPickupMapLocationPicker = false
                }
            )
        }
    }

    private func applyModeToFields() {
        switch mode {
        case .add:
            title = ""
            sport = sportChoices.first ?? "Soccer"
            let now = Date()
            gameDate = now
            gameTime = now
            address = ""
            city = ""
            state = ""
            description = ""
            playEnvironment = .either
            skillLevel = .casual
            participantPreference = .everyone
            costKind = .free
            entryFeeText = ""
            playersNeeded = 1
            useMaxPlayers = false
            maxPlayers = 10
            isVisible = true
            cleanupHours = 24
            coordinatesLockedFromMap = false
            mapPinnedCoordinate = nil
        case .edit(let row):
            title = row.title
            sport = row.sport
            if let start = PickupGameModels.parseSupabaseTimestamptz(row.game_start_at) {
                gameDate = start
                gameTime = start
            }
            address = row.address ?? ""
            city = row.city ?? ""
            state = row.state ?? ""
            description = row.description ?? ""
            playEnvironment = row.playEnvironmentEnum
            skillLevel = row.skillLevelEnum
            participantPreference = row.participantPreferenceEnum
            if row.is_free {
                costKind = .free
                entryFeeText = ""
            } else {
                costKind = .paid
                if let amt = row.entry_fee_amount {
                    entryFeeText = Self.feeTextFieldString(from: amt)
                } else {
                    entryFeeText = ""
                }
            }
            playersNeeded = row.playersNeededClamped
            if let cap = row.max_players {
                useMaxPlayers = true
                maxPlayers = min(100, Swift.max(1, cap))
            } else {
                useMaxPlayers = false
                maxPlayers = Swift.max(row.playersNeededClamped, 2)
            }
            isVisible = row.is_visible
            cleanupHours = row.cleanup_delay_hours
            coordinatesLockedFromMap = false
            mapPinnedCoordinate = nil
        }
    }

    private static func feeTextFieldString(from amount: Double) -> String {
        let n = NSNumber(value: amount)
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 2
        return f.string(from: n) ?? String(format: "%.2f", amount)
    }

    private func combinedStartDate() -> Date {
        VenueOwnerGameScheduleValidation.combinedLocalStart(gameDate: gameDate, gameStartTime: gameTime)
    }

    private func parsedEntryFeeAmount() -> Double? {
        let t = entryFeeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let normalized = t.replacingOccurrences(of: ",", with: "")
        return Double(normalized)
    }

    private func save() async {
        errorText = nil
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            errorText = "Title is required."
            return
        }
        if VenueOwnerGameScheduleValidation.isPastSchedule(gameDate: gameDate, gameStartTime: gameTime) {
            errorText = VenueOwnerGameScheduleValidation.futureDateTimeMessage
            return
        }

        let isFree = costKind == .free
        var feeParsed: Double?
        if !isFree {
            guard let amt = parsedEntryFeeAmount(), amt > 0, amt <= 999_999 else {
                errorText = "Enter a valid entry fee (USD)."
                return
            }
            feeParsed = (amt * 100.0).rounded() / 100.0
        }

        let playersN = min(20, max(1, playersNeeded))
        var maxP: Int?
        if useMaxPlayers {
            let capped = min(100, max(1, maxPlayers))
            guard capped >= playersN else {
                errorText = "Max players must be at least the number of players needed."
                return
            }
            maxP = capped
        }

        isSaving = true
        defer { isSaving = false }

        let start = combinedStartDate()

        guard hasCompleteTypedAddress else {
            if trimmedAddress.isEmpty && trimmedCity.isEmpty && trimmedState.isEmpty {
                errorText = "Location missing"
            } else {
                errorText = "Enter a complete street address, city, and state"
            }
            return
        }

        let addressLine = [trimmedAddress, trimmedCity, trimmedState].joined(separator: ", ")

        let latFinal: Double
        let lonFinal: Double
        if coordinatesLockedFromMap, let pin = mapPinnedCoordinate {
            latFinal = pin.latitude
            lonFinal = pin.longitude
        } else {
            guard let coord = await viewModel.geocodeAddress(addressLine) else {
                errorText = "Could not find that address. Please check the street address, city, and state."
                return
            }
            latFinal = coord.latitude
            lonFinal = coord.longitude
        }

        let addr = trimmedAddress
        let c = trimmedCity
        let st = trimmedState

        let desc = description.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            switch mode {
            case .add:
                _ = try await viewModel.insertPickupGame(
                    title: trimmedTitle,
                    sport: sport,
                    description: desc.isEmpty ? nil : desc,
                    skillLevel: skillLevel.rawValue,
                    gameStartAt: start,
                    address: addr.isEmpty ? nil : addr,
                    city: c.isEmpty ? nil : c,
                    state: st.isEmpty ? nil : st,
                    latitude: latFinal,
                    longitude: lonFinal,
                    isVisible: isVisible,
                    playersNeeded: playersN,
                    playEnvironment: playEnvironment.rawValue,
                    participantPreference: participantPreference.rawValue,
                    isFree: isFree,
                    entryFeeAmount: feeParsed,
                    maxPlayers: maxP,
                    cleanupDelayHours: cleanupHours
                )
            case .edit(let row):
                let patch = PickupGameFullUpdate(
                    title: trimmedTitle,
                    sport: sport,
                    description: desc.isEmpty ? nil : desc,
                    skill_level: skillLevel.rawValue,
                    game_start_at: PickupGameModels.encodeSupabaseTimestamptz(start),
                    address: addr.isEmpty ? nil : addr,
                    city: c.isEmpty ? nil : c,
                    state: st.isEmpty ? nil : st,
                    latitude: latFinal,
                    longitude: lonFinal,
                    is_visible: isVisible,
                    players_needed: playersN,
                    play_environment: playEnvironment.rawValue,
                    participant_preference: participantPreference.rawValue,
                    is_free: isFree,
                    entry_fee_amount: feeParsed,
                    max_players: maxP,
                    cleanup_delay_hours: cleanupHours
                )
                try await viewModel.updatePickupGame(id: row.id, full: patch)
            }
            await viewModel.refreshPickupGamesForDiscoverMap(force: true)
            onFinished()
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
