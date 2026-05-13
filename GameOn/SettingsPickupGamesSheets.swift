import CoreLocation
import MapKit
import SwiftUI

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

    var body: some View {
        List {
            if viewModel.myPickupGamesForSettings.isEmpty {
                Text("You have not posted a pickup game yet.")
                    .font(FGTypography.body)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .listRowBackground(FGColor.cardBackground(colorScheme))
            } else {
                ForEach(viewModel.myPickupGamesForSettings) { row in
                    Button {
                        formMode = .edit(row)
                    } label: {
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
                            if row.status != "active" {
                                Text("Removed")
                                    .font(FGTypography.caption.weight(.semibold))
                                    .foregroundStyle(FGColor.accentYellow)
                            } else if !row.is_visible {
                                Text("Hidden from map")
                                    .font(FGTypography.caption.weight(.semibold))
                                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if row.status == "active" {
                            Button(role: .destructive) {
                                deleteTarget = row
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
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
        .alert("Remove this pickup game?", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )) {
            Button("Cancel", role: .cancel) { deleteTarget = nil }
            Button("Remove", role: .destructive) {
                guard let row = deleteTarget else { return }
                deleteTarget = nil
                Task { await performDelete(row) }
            }
        } message: {
            Text("Others will no longer see it on the map.")
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
            await viewModel.refreshPickupGamesForDiscoverMap()
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
    @State private var pickedLatitude: Double?
    @State private var pickedLongitude: Double?
    @State private var mapLocationPickerPresented = false

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

    private var hasMapPinCoordinates: Bool {
        pickedLatitude != nil && pickedLongitude != nil
    }

    private var hasCompleteTypedAddress: Bool {
        !trimmedAddress.isEmpty && !trimmedCity.isEmpty && !trimmedState.isEmpty
    }

    /// Post/Save enabled when title is set and location can be resolved (map pin or full typed address).
    private var hasPlacedLocationForPostButton: Bool {
        hasMapPinCoordinates || hasCompleteTypedAddress
    }

    private var locationGuidanceFootnote: String? {
        if hasMapPinCoordinates { return nil }
        if hasCompleteTypedAddress { return nil }
        if trimmedAddress.isEmpty && trimmedCity.isEmpty && trimmedState.isEmpty {
            return "Location missing"
        }
        return "Pick a location or enter an address"
    }

    /// Map pin alone satisfies location; show this when the street field is still empty (e.g. park / pending reverse geocode).
    private var mapPinStreetEmptyHint: String? {
        guard hasMapPinCoordinates, trimmedAddress.isEmpty else { return nil }
        return "Pinned location selected"
    }

    private var mapPickerInitialCenter: CLLocationCoordinate2D {
        if let la = pickedLatitude, let lo = pickedLongitude {
            return CLLocationCoordinate2D(latitude: la, longitude: lo)
        }
        if case .edit(let row) = mode, let la = row.latitude, let lo = row.longitude {
            return CLLocationCoordinate2D(latitude: la, longitude: lo)
        }
        return CLLocationCoordinate2D(latitude: 40.3916, longitude: -111.8508)
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
                TextField("Street address", text: $address, axis: .vertical)
                    .lineLimit(1...3)
                if let hint = mapPinStreetEmptyHint {
                    Text(hint)
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.accentBlue)
                }
                TextField("City", text: $city)
                TextField("State", text: $state)

                Button {
                    mapLocationPickerPresented = true
                } label: {
                    Label("Pick location on map", systemImage: "mappin.and.ellipse")
                }

                if hasMapPinCoordinates {
                    HStack {
                        Text("Map pin set")
                            .font(FGTypography.caption)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                        Spacer()
                        Button("Clear map pin") {
                            pickedLatitude = nil
                            pickedLongitude = nil
                        }
                        .font(FGTypography.caption.weight(.semibold))
                    }
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
        .navigationTitle(mode.isAdd ? "Add pickup game" : "Edit pickup game")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { onFinished(); dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(mode.isAdd ? "Post" : "Save") {
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
        .sheet(isPresented: $mapLocationPickerPresented) {
            PickupGameMapLocationPickerSheet(
                initialCenter: mapPickerInitialCenter,
                onConfirm: { coord in
                    pickedLatitude = coord.latitude
                    pickedLongitude = coord.longitude
                    address = ""
                    city = ""
                    state = ""
                    Task {
                        let fields = await viewModel.reverseGeocodeAddressFields(for: coord)
                        await MainActor.run {
                            if let street = fields.street, !street.isEmpty {
                                address = street
                            }
                            if let c = fields.city, !c.isEmpty {
                                city = c
                            }
                            if let s = fields.state, !s.isEmpty {
                                state = s
                            }
                        }
                    }
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
            pickedLatitude = nil
            pickedLongitude = nil
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
            pickedLatitude = row.latitude
            pickedLongitude = row.longitude
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

        var lat: Double?
        var lon: Double?

        if let pl = pickedLatitude, let plo = pickedLongitude {
            lat = pl
            lon = plo
        } else {
            if trimmedAddress.isEmpty && trimmedCity.isEmpty && trimmedState.isEmpty {
                errorText = "Location missing"
                return
            }
            guard hasCompleteTypedAddress else {
                errorText = "Pick a location or enter an address"
                return
            }
            let addressLine = [trimmedAddress, trimmedCity, trimmedState].joined(separator: ", ")
            guard let coord = await viewModel.geocodeAddress(addressLine) else {
                errorText = "Pick a location or enter an address"
                return
            }
            lat = coord.latitude
            lon = coord.longitude
        }

        guard let latFinal = lat, let lonFinal = lon else {
            errorText = "Location missing"
            return
        }

        var addr = trimmedAddress
        var c = trimmedCity
        var st = trimmedState
        if hasMapPinCoordinates, addr.isEmpty {
            addr = "Pinned location"
        }

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
            await viewModel.refreshPickupGamesForDiscoverMap()
            onFinished()
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: - Map location picker (pickup game form)

private struct PickupGameMapLocationPickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let initialCenter: CLLocationCoordinate2D
    let onConfirm: (CLLocationCoordinate2D) -> Void

    @State private var position: MapCameraPosition
    @State private var pinCenter: CLLocationCoordinate2D

    init(initialCenter: CLLocationCoordinate2D, onConfirm: @escaping (CLLocationCoordinate2D) -> Void) {
        self.initialCenter = initialCenter
        self.onConfirm = onConfirm
        let span = MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)
        let region = MKCoordinateRegion(center: initialCenter, span: span)
        _position = State(initialValue: .region(region))
        _pinCenter = State(initialValue: initialCenter)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Map(position: $position)
                    .mapStyle(.standard(elevation: .realistic))
                    .onMapCameraChange(frequency: .onEnd) { context in
                        pinCenter = context.region.center
                    }

                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(.orange)
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
                    .allowsHitTesting(false)

                VStack {
                    Text("Pan the map to place the pin.")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .padding(.top, 12)
                    Spacer()
                }
                .allowsHitTesting(false)
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("Pick location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onConfirm(pinCenter)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear {
            if let c = position.region?.center {
                pinCenter = c
            }
        }
    }
}

private extension PickupGameFormMode {
    var isAdd: Bool {
        if case .add = self { return true }
        return false
    }
}
