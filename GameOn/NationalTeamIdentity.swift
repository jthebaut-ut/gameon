import SwiftUI

struct NationalTeamIdentity: Equatable, Codable {
    let countryCode: String
    let countryName: String
    let flag: String
    let supporterLabel: String

    var displayTitle: String {
        displayTitle(languageCode: L10n.defaultLanguageCode)
    }

    func resolvedSupporterLabel(languageCode: String) -> String {
        NationalTeamCopy.resolvedSupporterLabel(
            rawLabel: supporterLabel,
            countryName: countryName,
            languageCode: languageCode
        )
    }

    func displayTitle(languageCode: String) -> String {
        "\(flag) \(resolvedSupporterLabel(languageCode: languageCode))"
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
    static let defaultSupporterLabelKey = "national_team_label_fan"

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
        L10n.logMissingKeyOnce(key, prefix: "missingNationalTeamKey")
#endif
        return fallback
    }

    static func defaultSupporterLabel(countryName: String, languageCode: String) -> String {
        "\(countryName) \(text(defaultSupporterLabelKey, languageCode: languageCode))"
    }

    static func storageSupporterLabelKey(from rawLabel: String) -> String {
        let trimmed = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultSupporterLabelKey }
        if fallbacks.keys.contains(trimmed) { return trimmed }

        let normalized = trimmed.lowercased()
        if normalized.contains("supporter") { return "national_team_label_supporter" }
        if normalized.contains("till i die") { return "national_team_label_till_i_die" }
        if normalized.contains("representing") { return "national_team_label_representing" }
        if normalized.contains("fan") { return defaultSupporterLabelKey }
        return defaultSupporterLabelKey
    }

    static func resolvedSupporterLabel(rawLabel: String, countryName: String, languageCode: String) -> String {
        let trimmed = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = defaultSupporterLabel(countryName: countryName, languageCode: languageCode)
        guard !trimmed.isEmpty else { return fallback }

        if fallbacks.keys.contains(trimmed) {
            return "\(countryName) \(text(trimmed, languageCode: languageCode))"
        }

        if trimmed.contains("_") {
#if DEBUG
            L10n.logMissingKeyOnce(trimmed, prefix: "missingNationalTeamKey")
#endif
            return fallback
        }

        let knownDisplaySuffixes = fallbacks.keys
            .map { text($0, languageCode: languageCode) }
            .filter { !$0.isEmpty }
        if knownDisplaySuffixes.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return "\(countryName) \(trimmed)"
        }

        if trimmed.localizedCaseInsensitiveContains(countryName) {
            return trimmed
        }

        return fallback
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
    var compact = false
    var onTap: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    var body: some View {
        let flagFrame: CGFloat = compact ? 58 : 46
        let flagFont: CGFloat = compact ? 40 : 34
        let cardCorner: CGFloat = compact ? 22 : 20
        let horizontalPadding: CGFloat = compact ? 16 : 13
        let verticalPadding: CGFloat = compact ? 15 : 13
        let minCardHeight: CGFloat? = compact ? 92 : nil
        Button {
            onTap?()
        } label: {
            HStack(spacing: compact ? 14 : 12) {
                Text(identity.flag)
                    .font(.system(size: flagFont))
                    .frame(width: flagFrame, height: flagFrame)
                    .minimumScaleFactor(0.8)
                    .lineLimit(1)
                    .background {
                        Circle()
                            .fill(Color.white.opacity(compact ? (colorScheme == .dark ? 0.15 : 0.86) : (colorScheme == .dark ? 0.10 : 0.78)))
                            .overlay {
                                Circle()
                                    .strokeBorder(
                                        Color.white.opacity(compact ? (colorScheme == .dark ? 0.22 : 0.78) : 0),
                                        lineWidth: compact ? 1 : 0
                                    )
                            }
                    }
                    .shadow(
                        color: FGColor.accentBlue.opacity(compact ? (colorScheme == .dark ? 0.18 : 0.12) : 0),
                        radius: compact ? 10 : 0,
                        y: compact ? 5 : 0
                    )

                VStack(alignment: .leading, spacing: compact ? 5 : 4) {
                    Text(identity.resolvedSupporterLabel(languageCode: appLanguageRaw))
                        .font(.system(size: compact ? 18 : 17, weight: .heavy, design: .rounded))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    HStack(spacing: 6) {
                        Image(systemName: "soccerball")
                            .font(.system(size: compact ? 11 : 10, weight: .bold))
                        Text(NationalTeamCopy.text("world_cup_2026", languageCode: appLanguageRaw))
                            .font(.system(size: compact ? 12 : 11, weight: .bold, design: .rounded))
                            .lineLimit(1)
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
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: .infinity, minHeight: minCardHeight, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: cardCorner, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                FGColor.accentGreen.opacity(compact ? (colorScheme == .dark ? 0.28 : 0.18) : (colorScheme == .dark ? 0.22 : 0.13)),
                                FGColor.accentBlue.opacity(compact ? (colorScheme == .dark ? 0.22 : 0.13) : (colorScheme == .dark ? 0.18 : 0.10)),
                                Color.white.opacity(compact ? (colorScheme == .dark ? 0.08 : 0.80) : (colorScheme == .dark ? 0.06 : 0.72))
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(alignment: .topTrailing) {
                        if compact {
                            Circle()
                                .fill(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.10 : 0.08))
                                .frame(width: 86, height: 86)
                                .offset(x: 24, y: -36)
                        }
                    }
            }
            .overlay {
                if compact {
                    RoundedRectangle(cornerRadius: cardCorner, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(colorScheme == .dark ? 0.12 : 0.86),
                                    FGColor.accentGreen.opacity(colorScheme == .dark ? 0.32 : 0.24),
                                    FGColor.accentBlue.opacity(colorScheme == .dark ? 0.22 : 0.16)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                } else {
                    RoundedRectangle(cornerRadius: cardCorner, style: .continuous)
                        .strokeBorder(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.30 : 0.20), lineWidth: 1)
                }
            }
            .shadow(color: FGColor.accentGreen.opacity(colorScheme == .dark ? 0.12 : 0.08), radius: compact ? 16 : 0, y: compact ? 8 : 0)
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
        return NationalTeamIdentity(
            countryCode: country.code,
            countryName: country.name,
            flag: country.flag,
            supporterLabel: NationalTeamCopy.defaultSupporterLabelKey
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
            print("[NationalTeamDebug] resolvedLabel=\(identity.resolvedSupporterLabel(languageCode: appLanguageRaw))")
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
