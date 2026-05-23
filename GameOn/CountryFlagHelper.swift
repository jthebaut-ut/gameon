import Foundation

enum CountryFlagHelper {
    private static let aliasesByRegionCode: [String: [String]] = [
        "AR": ["argentina"],
        "AU": ["australia"],
        "BE": ["belgium", "belgië", "belgique"],
        "BO": ["bolivia", "bol"],
        "BR": ["brazil", "brasil"],
        "CA": ["canada"],
        "CL": ["chile"],
        "CH": ["switzerland", "swiss"],
        "CN": ["china", "pr china"],
        "CO": ["colombia"],
        "CR": ["costa rica"],
        "DE": ["germany", "deutschland"],
        "DK": ["denmark"],
        "EC": ["ecuador"],
        "EG": ["egypt"],
        "ES": ["spain", "españa"],
        "FR": ["france"],
        "GB": ["great britain", "britain", "uk", "united kingdom", "england", "scotland", "wales"],
        "HR": ["croatia"],
        "IT": ["italy", "italia"],
        "JP": ["japan"],
        "KR": ["south korea", "korea", "republic of korea"],
        "MA": ["morocco"],
        "MX": ["mexico", "méxico"],
        "NL": ["netherlands", "holland"],
        "NO": ["norway"],
        "PE": ["peru"],
        "PL": ["poland", "polska"],
        "PT": ["portugal"],
        "RS": ["serbia"],
        "RU": ["russia"],
        "SA": ["saudi arabia"],
        "SE": ["sweden"],
        "SN": ["senegal"],
        "TR": ["turkey", "turkiye", "türkiye"],
        "US": ["usa", "u.s.a.", "us", "u.s.", "united states", "united states of america", "america"],
        "UY": ["uruguay"]
    ]

    private static let regionCodeByAlias: [String: String] = {
        aliasesByRegionCode.reduce(into: [String: String]()) { result, entry in
            for alias in entry.value {
                result[normalize(alias)] = entry.key
            }
        }
    }()

    static func flag(for teamName: String) -> String? {
        regionCode(for: teamName).map(flagEmoji)
    }

    static func countryCode(for teamName: String) -> String? {
        regionCode(for: teamName)
    }

    static func isCountry(_ teamName: String) -> Bool {
        regionCode(for: teamName) != nil
    }

    static func displayName(for teamName: String, languageCode: String? = nil) -> String {
        guard let regionCode = regionCode(for: teamName) else {
            return teamName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let localeIdentifier = L10n.normalizedLanguageCode(languageCode ?? UserDefaults.standard.string(forKey: L10n.appLanguageKey))
        let localized = Locale(identifier: localeIdentifier).localizedString(forRegionCode: regionCode)
        let trimmedLocalized = localized?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedLocalized.isEmpty
            ? teamName.trimmingCharacters(in: .whitespacesAndNewlines)
            : trimmedLocalized
    }

    static func countrySuggestions(matching query: String, languageCode: String? = nil) -> [(name: String, code: String, flag: String)] {
        let normalizedQuery = normalize(query)
        let localeIdentifier = L10n.normalizedLanguageCode(languageCode ?? UserDefaults.standard.string(forKey: L10n.appLanguageKey))
        return aliasesByRegionCode.keys.sorted().compactMap { code in
            let localized = Locale(identifier: localeIdentifier).localizedString(forRegionCode: code) ?? code
            let aliases = aliasesByRegionCode[code] ?? []
            guard normalizedQuery.isEmpty
                    || normalize(localized).contains(normalizedQuery)
                    || aliases.contains(where: { normalize($0).contains(normalizedQuery) }) else {
                return nil
            }
            return (name: localized, code: code, flag: flagEmoji(forRegionCode: code))
        }
    }

    private static func regionCode(for teamName: String) -> String? {
        let uppercasedCode = teamName.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if aliasesByRegionCode.keys.contains(uppercasedCode) {
            return uppercasedCode
        }

        let normalized = normalize(teamName)
        guard !normalized.isEmpty else { return nil }
        if let direct = regionCodeByAlias[normalized] {
            return direct
        }
        return regionCodeByAlias.first { alias, _ in
            normalized == alias || normalized.hasSuffix(" \(alias)")
        }?.value
    }

    private static func normalize(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "&", with: " and ")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    nonisolated private static func flagEmoji(forRegionCode regionCode: String) -> String {
        let scalars = regionCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .unicodeScalars
        guard scalars.count == 2,
              scalars.allSatisfy({ (65...90).contains($0.value) }) else {
            return ""
        }
        return scalars
            .compactMap { UnicodeScalar(127397 + $0.value) }
            .map(String.init)
            .joined()
    }
}
