import SwiftUI

enum ManualVenueTeamType: String {
    case country
    case club
    case custom
}

struct ManualVenueTeamSelection: Equatable {
    let name: String
    let type: ManualVenueTeamType
    let countryCode: String?

    var flag: String? {
        guard type == .country else { return nil }
        return CountryFlagHelper.flag(for: name)
    }
}

enum ManualVenueTeamResolver {
    static func resolve(_ raw: String) -> ManualVenueTeamSelection {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let code = CountryFlagHelper.countryCode(for: name) {
            return ManualVenueTeamSelection(
                name: CountryFlagHelper.displayName(for: name),
                type: .country,
                countryCode: code
            )
        }
        if let team = FavoriteTeamCatalog.searchTeams(name).first(where: { candidate in
            candidate.kind == .team && matches(candidate, query: name)
        }) {
            return ManualVenueTeamSelection(name: team.name, type: .club, countryCode: nil)
        }
        if let providerSelection = SportsTeamPickerData.exactOption(named: name) {
            return ManualVenueTeamSelection(
                name: providerSelection.displayName,
                type: providerSelection.mode == .countries ? .country : .club,
                countryCode: providerSelection.themeHint
            )
        }
        return ManualVenueTeamSelection(name: name, type: .custom, countryCode: nil)
    }

    private static func matches(_ team: FavoriteTeam, query: String) -> Bool {
        let normalizedQuery = normalize(query)
        guard !normalizedQuery.isEmpty else { return false }
        let names = [team.name, team.shortCode ?? ""] + team.searchAliases
        return names.contains { normalize($0) == normalizedQuery }
    }

    private static func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }
}

struct ManualTeamAutocompleteView: View {
    let title: String
    @Binding var text: String
    let sportName: String
    let unavailableTeamName: String
    let onTextChanged: (String) -> Void
    let onSelection: (ManualVenueTeamSelection) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode
    @State private var pickerMode: TeamPickerMode = .countries
    @State private var pickerSearchText = ""
    @State private var isPickerPresented = false

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedPickerSearchText: String {
        pickerSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var regionGroups: [TeamPickerRegionGroup] {
        SportsTeamPickerData.regionGroups(
            sportName: sportName,
            mode: pickerMode,
            query: pickerSearchText
        )
    }

    private var customSuggestion: TeamPickerOption? {
        let query = trimmedPickerSearchText
        guard !query.isEmpty else { return nil }
        let merged = regionGroups.flatMap { $0.groups }.flatMap(\.options)
        if merged.contains(where: { $0.displayName.caseInsensitiveCompare(query) == .orderedSame }) {
            return nil
        }
        return TeamPickerOption(
            id: "custom-\(query.lowercased())",
            displayName: query,
            shortName: nil,
            sport: TeamPickerSport.resolve(sportName),
            mode: pickerMode,
            region: "Custom",
            leagueGroup: L10n.t("use_custom_team", languageCode: appLanguageRaw),
            emoji: "✎",
            themeHint: "custom"
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))

            teamInputRow
        }
        .onAppear {
            pickerMode = SportsTeamPickerData.preferredMode(for: sportName)
        }
        .onChange(of: sportName) { _, newSport in
            pickerMode = SportsTeamPickerData.preferredMode(for: newSport)
        }
        .sheet(isPresented: $isPickerPresented) {
            NavigationStack {
                pickerSheetContent
                    .navigationTitle(title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") {
                                isPickerPresented = false
                            }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private var teamInputRow: some View {
        HStack(spacing: 9) {
            TextField("Search or enter team/country name", text: Binding(
                get: { text },
                set: { value in
                    onTextChanged(value)
                }
            ))
            .textInputAutocapitalization(.words)
            .autocorrectionDisabled(false)
            .font(.subheadline.weight(.semibold))

            if !trimmedText.isEmpty {
                Button {
                    onTextChanged("")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear \(title)")
            }

            Divider()
                .frame(height: 22)

            Button {
                openPicker()
            } label: {
                Image(systemName: "globe.americas.fill")
                    .font(.subheadline.weight(.heavy))
                    .foregroundStyle(FGColor.accentGreen)
                    .frame(width: 30, height: 34)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(title) team picker")
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 48)
        .background(FGAdaptiveSurface.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    trimmedText.isEmpty ? FGColor.divider(colorScheme).opacity(0.45) : FGColor.accentGreen.opacity(0.34),
                    lineWidth: 1
                )
        }
    }

    private var pickerSheetContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            modePicker

            pickerSearchBar

            if !trimmedText.isEmpty {
                selectedTeamSummary
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    groupedChipSections

                    if let customSuggestion {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Custom")
                                .font(.caption2.weight(.heavy))
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                            suggestionButton(customSuggestion)
                        }
                    }
                }
                .padding(.bottom, 20)
            }
        }
        .padding()
        .background(FGAdaptiveSurface.sheetRoot.ignoresSafeArea())
        .onAppear {
            pickerSearchText = trimmedText
        }
    }

    private var pickerSearchBar: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.caption.weight(.bold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
            TextField("Search country or team", text: $pickerSearchText)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled(false)
                .font(.subheadline.weight(.semibold))
            if !trimmedPickerSearchText.isEmpty {
                Button {
                    pickerSearchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(FGAdaptiveSurface.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func openPicker() {
        pickerMode = SportsTeamPickerData.preferredMode(for: sportName)
        pickerSearchText = trimmedText
        isPickerPresented = true
    }

    private var modePicker: some View {
        HStack(spacing: 2) {
            ForEach(TeamPickerMode.allCases) { mode in
                Button {
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
                        pickerMode = mode
                    }
                } label: {
                    Text(mode.rawValue)
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(pickerMode == mode ? Color.white : FGColor.secondaryText(colorScheme))
                        .padding(.horizontal, 8)
                        .frame(height: 30)
                        .background {
                            Capsule(style: .continuous)
                                .fill(pickerMode == mode ? FGColor.accentGreen : Color.clear)
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(FGAdaptiveSurface.controlFill)
        .clipShape(Capsule(style: .continuous))
    }

    private var selectedTeamSummary: some View {
        HStack(spacing: 8) {
            Text(selectedIcon(for: trimmedText))
                .font(.caption.weight(.bold))
            Text("Selected: \(trimmedText)")
                .font(.caption.weight(.bold))
                .lineLimit(1)
            Spacer(minLength: 0)
            Button {
                onTextChanged("")
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.14 : 0.08))
        .clipShape(Capsule(style: .continuous))
    }

    private var groupedChipSections: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(regionGroups) { region in
                VStack(alignment: .leading, spacing: 9) {
                    Text(region.title)
                        .font(.subheadline.weight(.heavy))
                        .foregroundStyle(FGColor.primaryText(colorScheme))

                    ForEach(region.groups) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(group.title)
                                .font(.caption2.weight(.heavy))
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 7) {
                                    ForEach(group.options) { option in
                                        teamChip(option)
                                    }
                                }
                                .padding(.vertical, 1)
                            }
                        }
                    }
                }
            }
        }
    }

    private func teamChip(_ option: TeamPickerOption) -> some View {
        let selected = isSelected(option)
        let unavailable = isUnavailable(option)
        let tint = tint(for: option)
        return Button {
            select(option)
        } label: {
            HStack(spacing: 5) {
                if let emoji = option.emoji {
                    Text(emoji)
                        .font(.caption)
                }
                Text(option.displayName)
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? Color.white : tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background {
                Capsule(style: .continuous)
                    .fill(selected ? tint : tint.opacity(colorScheme == .dark ? 0.16 : 0.09))
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(tint.opacity(selected ? 0.85 : 0.22), lineWidth: selected ? 1.3 : 1)
            }
            .opacity(unavailable ? 0.38 : 1)
        }
        .buttonStyle(.plain)
        .disabled(unavailable)
    }

    private func suggestionButton(_ option: TeamPickerOption) -> some View {
        let unavailable = isUnavailable(option)
        let tint = tint(for: option)
        return Button {
            select(option)
        } label: {
            HStack(spacing: 10) {
                if let emoji = option.emoji {
                    Text(emoji)
                        .font(.title3)
                        .frame(width: 26)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: L10n.t("use_custom_team_format", languageCode: appLanguageRaw), option.displayName))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(1)
                    Text(option.leagueGroup)
                        .font(.caption2)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(tint.opacity(colorScheme == .dark ? 0.13 : 0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .opacity(unavailable ? 0.42 : 1)
        }
        .buttonStyle(.plain)
        .disabled(unavailable)
    }

    private func select(_ option: TeamPickerOption) {
        guard !isUnavailable(option) else { return }
        let selection = ManualVenueTeamSelection(
            name: option.displayName,
            type: selectionType(for: option),
            countryCode: option.mode == .countries ? option.themeHint : nil
        )
        text = selection.name
        pickerSearchText = selection.name
        onSelection(selection)
        isPickerPresented = false
    }

    private func isSelected(_ option: TeamPickerOption) -> Bool {
        trimmedText.localizedCaseInsensitiveCompare(option.displayName) == .orderedSame
    }

    private func isUnavailable(_ option: TeamPickerOption) -> Bool {
        let other = unavailableTeamName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !other.isEmpty else { return false }
        return other.localizedCaseInsensitiveCompare(option.displayName) == .orderedSame
    }

    private func selectionType(for option: TeamPickerOption) -> ManualVenueTeamType {
        if option.themeHint == "custom" { return .custom }
        return option.mode == .countries ? .country : .club
    }

    private func tint(for option: TeamPickerOption) -> Color {
        if option.themeHint == "custom" { return FGColor.accentBlue }
        if option.mode == .countries { return FGColor.accentGreen }
        return sportAccentColor(for: sportName)
    }

    private func selectedIcon(for name: String) -> String {
        if let flag = CountryFlagHelper.flag(for: name) {
            return flag
        }
        return pickerMode == .teams ? "✓" : "🌍"
    }
}
