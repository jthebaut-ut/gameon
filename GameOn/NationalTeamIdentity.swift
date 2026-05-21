import SwiftUI

struct NationalTeamIdentity: Equatable, Codable {
    let countryCode: String
    let countryName: String
    let flag: String
    let supporterLabel: String

    var displayTitle: String {
        "\(flag) \(supporterLabel)"
    }

    static func fromProfile(
        countryCode: String?,
        countryName: String?,
        flag: String?,
        supporterLabel: String?
    ) -> NationalTeamIdentity? {
        let code = countryCode?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
        let name = countryName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !code.isEmpty, !name.isEmpty else { return nil }
        let resolvedFlag = flag?.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = supporterLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return NationalTeamIdentity(
            countryCode: code,
            countryName: name,
            flag: resolvedFlag?.isEmpty == false ? resolvedFlag! : (CountryFlagHelper.flag(for: name) ?? ""),
            supporterLabel: label.isEmpty ? "\(name) Fan" : label
        )
    }
}

enum NationalTeamCopy {
    private static let fallbacks: [String: String] = [
        "national_team": "National Team",
        "national_team_subtitle": "Represent your country for World Cup season.",
        "choose_national_team": "Choose National Team",
        "who_are_you_supporting": "Who are you supporting?",
        "choose_national_team_subtitle": "Choose your national team",
        "search_countries": "Search countries",
        "world_cup_2026": "World Cup 2026",
        "national_team_label_fan": "Fan",
        "national_team_label_supporter": "Supporter",
        "national_team_label_till_i_die": "Till I Die",
        "national_team_label_representing": "Representing"
    ]

    static func text(_ key: String, languageCode: String) -> String {
        let localized = L10n.t(key, languageCode: languageCode)
        guard localized == key, let fallback = fallbacks[key] else {
            return localized
        }
#if DEBUG
        print("[LocalizationDebug] missingNationalTeamKey=\(key)")
#endif
        return fallback
    }

    static func defaultSupporterLabel(countryName: String, languageCode: String) -> String {
        "\(countryName) \(text("national_team_label_fan", languageCode: languageCode))"
    }
}

struct NationalTeamCountryOption: Identifiable, Equatable {
    let code: String
    let name: String
    let flag: String
    let isPopular: Bool

    var id: String { "\(code)-\(name)" }
}

enum NationalTeamCountryCatalog {
    private static let popularNames = [
        "United States", "Mexico", "France", "Argentina", "Brazil", "England", "Spain", "Germany",
        "Italy", "Portugal", "Netherlands", "Belgium", "Canada", "Morocco", "Japan", "South Korea"
    ]

    static func popularOptions() -> [NationalTeamCountryOption] {
        popularNames.compactMap { option(named: $0, popular: true) }
    }

    static func options(matching query: String, languageCode: String) -> [NationalTeamCountryOption] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return popularOptions() }
        let popular = popularOptions().filter { option in
            option.name.localizedCaseInsensitiveContains(trimmed)
                || option.code.localizedCaseInsensitiveContains(trimmed)
        }
        var seen = Set(popular.map(\.id))
        let all = CountryFlagHelper.countrySuggestions(matching: trimmed, languageCode: languageCode)
            .map {
                NationalTeamCountryOption(
                    code: $0.code,
                    name: $0.name,
                    flag: $0.flag,
                    isPopular: false
                )
            }
            .filter { seen.insert($0.id).inserted }
        return popular + all
    }

    static func option(named name: String, popular: Bool = false) -> NationalTeamCountryOption? {
        guard let code = CountryFlagHelper.countryCode(for: name),
              let flag = CountryFlagHelper.flag(for: name) else { return nil }
        return NationalTeamCountryOption(code: code, name: name, flag: flag, isPopular: popular)
    }
}

struct NationalTeamIdentityCard: View {
    let identity: NationalTeamIdentity
    var showsEditAffordance = false
    var onTap: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    var body: some View {
        Button {
            onTap?()
        } label: {
            HStack(spacing: 12) {
                Text(identity.flag)
                    .font(.system(size: 34))
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(Color.white.opacity(colorScheme == .dark ? 0.10 : 0.78)))

                VStack(alignment: .leading, spacing: 4) {
                    Text(identity.supporterLabel)
                        .font(.system(size: 17, weight: .heavy, design: .rounded))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    HStack(spacing: 6) {
                        Image(systemName: "soccerball")
                            .font(.system(size: 10, weight: .bold))
                        Text(NationalTeamCopy.text("world_cup_2026", languageCode: appLanguageRaw))
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(FGColor.accentGreen)
                }

                Spacer(minLength: 0)

                if showsEditAffordance {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }
            }
            .padding(13)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                FGColor.accentGreen.opacity(colorScheme == .dark ? 0.22 : 0.13),
                                FGColor.accentBlue.opacity(colorScheme == .dark ? 0.18 : 0.10),
                                Color.white.opacity(colorScheme == .dark ? 0.06 : 0.72)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.30 : 0.20), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(onTap == nil)
        .accessibilityElement(children: .combine)
    }
}

struct NationalTeamPickerSheet: View {
    let currentIdentity: NationalTeamIdentity?
    let onSave: (NationalTeamIdentity) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode
    @State private var searchText = ""

    private var options: [NationalTeamCountryOption] {
        NationalTeamCountryCatalog.options(matching: searchText, languageCode: appLanguageRaw)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(NationalTeamCopy.text("who_are_you_supporting", languageCode: appLanguageRaw))
                            .font(.title2.weight(.heavy))
                        Text(NationalTeamCopy.text("choose_national_team_subtitle", languageCode: appLanguageRaw))
                            .font(.subheadline)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    }

                    searchField

                    VStack(alignment: .leading, spacing: 8) {
                        Text(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Popular" : "Countries")
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .textCase(.uppercase)
                        ForEach(options) { option in
                            countryRow(option)
                        }
                    }
                }
                .padding(18)
            }
            .background(FGColor.screenGradient(colorScheme).ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("cancel", languageCode: appLanguageRaw)) { dismiss() }
                }
            }
        }
    }

    private func identity(for country: NationalTeamCountryOption) -> NationalTeamIdentity {
        let label = NationalTeamCopy.defaultSupporterLabel(countryName: country.name, languageCode: appLanguageRaw)
        return NationalTeamIdentity(
            countryCode: country.code,
            countryName: country.name,
            flag: country.flag,
            supporterLabel: label
        )
    }

    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.caption.weight(.bold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
            TextField(NationalTeamCopy.text("search_countries", languageCode: appLanguageRaw), text: $searchText)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
        }
        .padding()
        .background(FGAdaptiveSurface.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func countryRow(_ option: NationalTeamCountryOption) -> some View {
        Button {
            let identity = identity(for: option)
#if DEBUG
            print("[NationalTeamDebug] selectedCountry=\(option.name)")
            print("[NationalTeamDebug] countrySelected code=\(option.code)")
            print("[NationalTeamDebug] resolvedLabel=\(identity.supporterLabel)")
#endif
            onSave(identity)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Text(option.flag)
                    .font(.title2)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.name)
                        .font(.subheadline.weight(.bold))
                    Text(option.code)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }
                Spacer()
                if currentIdentity?.countryCode == option.code {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(FGColor.accentGreen)
                }
            }
            .padding(12)
            .background(FGAdaptiveSurface.controlFill)
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
