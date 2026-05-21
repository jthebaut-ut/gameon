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

private struct ManualVenueTeamSuggestion: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let type: ManualVenueTeamType
    let countryCode: String?
    let flag: String?
    let symbol: String?
    let tint: Color
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
    let showSoccerCountryChips: Bool
    let onTextChanged: (String) -> Void
    let onSelection: (ManualVenueTeamSelection) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode
    @State private var showMoreCountryChips = false

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSoccerContext: Bool {
        sportName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().contains("soccer")
    }

    private var suggestions: [ManualVenueTeamSuggestion] {
        let query = trimmedText
        let countrySuggestions = CountryFlagHelper.countrySuggestions(matching: query)
            .prefix(6)
            .map { country in
                ManualVenueTeamSuggestion(
                    id: "country-\(country.code)",
                    title: country.name,
                    subtitle: L10n.t("Country", languageCode: appLanguageRaw),
                    type: .country,
                    countryCode: country.code,
                    flag: country.flag,
                    symbol: nil,
                    tint: FGColor.accentGreen
                )
            }

        let teamSuggestions = FavoriteTeamCatalog.searchTeams(query)
            .filter { $0.kind == .team }
            .prefix(6)
            .map { team in
                ManualVenueTeamSuggestion(
                    id: "club-\(team.id)",
                    title: team.name,
                    subtitle: team.league,
                    type: .club,
                    countryCode: nil,
                    flag: nil,
                    symbol: team.fallbackSymbol,
                    tint: team.badgeColor
                )
            }

        var merged = isSoccerContext
            ? Array(countrySuggestions) + Array(teamSuggestions)
            : Array(teamSuggestions) + Array(countrySuggestions)
        if !query.isEmpty,
           !merged.contains(where: { $0.title.caseInsensitiveCompare(query) == .orderedSame }) {
            merged.append(
                ManualVenueTeamSuggestion(
                    id: "custom-\(query.lowercased())",
                    title: query,
                    subtitle: L10n.t("use_custom_team", languageCode: appLanguageRaw),
                    type: .custom,
                    countryCode: nil,
                    flag: nil,
                    symbol: "text.cursor",
                    tint: FGColor.accentBlue
                )
            )
        }
        return merged
    }

    private var quickCountries: [(name: String, code: String, flag: String)] {
        let primary = ["USA", "Mexico", "France", "Brazil", "Argentina"]
        let more = ["Belgium", "Spain", "Germany", "Portugal", "England", "Italy"]
        let names = showMoreCountryChips ? primary + more : primary
        return names.compactMap { name in
            guard let code = CountryFlagHelper.countryCode(for: name),
                  let flag = CountryFlagHelper.flag(for: name) else { return nil }
            return (name: CountryFlagHelper.displayName(for: name), code: code, flag: flag)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))

            HStack(spacing: 9) {
                if let flag = CountryFlagHelper.flag(for: trimmedText) {
                    Text(flag)
                        .font(.title3)
                } else {
                    Image(systemName: "magnifyingglass")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }

                TextField(L10n.t("search_country_or_team", languageCode: appLanguageRaw), text: Binding(
                    get: { text },
                    set: { value in
                        onTextChanged(value)
                    }
                ))
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled(false)
                .font(.subheadline.weight(.semibold))
            }
            .padding()
            .background(FGAdaptiveSurface.controlFill)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            if showSoccerCountryChips {
                quickCountryChips
            }

            if isEnabled && !trimmedText.isEmpty && !suggestions.isEmpty {
                VStack(spacing: 6) {
                    ForEach(suggestions.prefix(8)) { suggestion in
                        suggestionButton(suggestion)
                    }
                }
                .padding(8)
                .background(FGAdaptiveSurface.sheetRoot.opacity(colorScheme == .dark ? 0.58 : 0.84))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    private var quickCountryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(quickCountries, id: \.code) { country in
                    Button {
                        select(
                            ManualVenueTeamSuggestion(
                                id: "quick-\(country.code)",
                                title: country.name,
                                subtitle: L10n.t("Country", languageCode: appLanguageRaw),
                                type: .country,
                                countryCode: country.code,
                                flag: country.flag,
                                symbol: nil,
                                tint: FGColor.accentGreen
                            )
                        )
                    } label: {
                        Text("\(country.flag) \(country.name)")
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.18 : 0.11))
                            .clipShape(Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
                        showMoreCountryChips.toggle()
                    }
                } label: {
                    Text(showMoreCountryChips ? L10n.t("less", languageCode: appLanguageRaw) : L10n.t("more_plus", languageCode: appLanguageRaw))
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.18 : 0.11))
                        .clipShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 1)
        }
    }

    private func suggestionButton(_ suggestion: ManualVenueTeamSuggestion) -> some View {
        Button {
            select(suggestion)
        } label: {
            HStack(spacing: 10) {
                if let flag = suggestion.flag {
                    Text(flag)
                        .font(.title3)
                        .frame(width: 26)
                } else if let symbol = suggestion.symbol {
                    Image(systemName: symbol)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(suggestion.tint)
                        .frame(width: 26)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.type == .custom ? String(format: L10n.t("use_custom_team_format", languageCode: appLanguageRaw), suggestion.title) : suggestion.title)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(1)
                    Text(suggestion.subtitle)
                        .font(.caption2)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(suggestion.tint.opacity(colorScheme == .dark ? 0.13 : 0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func select(_ suggestion: ManualVenueTeamSuggestion) {
        let selection = ManualVenueTeamSelection(
            name: suggestion.title,
            type: suggestion.type,
            countryCode: suggestion.countryCode
        )
        text = selection.name
        onSelection(selection)
    }
}
