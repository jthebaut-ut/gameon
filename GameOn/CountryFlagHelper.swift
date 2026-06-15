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
        "CW": ["curacao", "curaçao"],
        "CZ": ["czech republic", "czechia", "czech"],
        "CD": ["dr congo", "d r congo", "democratic republic of congo", "congo dr", "congo kinshasa"],
        "CI": ["ivory coast", "cote d ivoire", "côte d ivoire"],
        "DE": ["germany", "deutschland"],
        "DK": ["denmark"],
        "EC": ["ecuador"],
        "EG": ["egypt"],
        "ES": ["spain", "españa"],
        "FR": ["france"],
        "GB": ["great britain", "britain", "uk", "united kingdom", "england", "scotland", "wales", "northern ireland"],
        "GH": ["ghana"],
        "HT": ["haiti"],
        "HR": ["croatia"],
        "IQ": ["iraq"],
        "IR": ["iran"],
        "IT": ["italy", "italia"],
        "JO": ["jordan"],
        "JP": ["japan"],
        "KR": ["south korea", "korea", "republic of korea"],
        "KP": ["north korea", "dpr korea", "korea dpr"],
        "MA": ["morocco"],
        "MX": ["mexico", "méxico"],
        "NL": ["netherlands", "holland"],
        "NO": ["norway"],
        "NZ": ["new zealand"],
        "PA": ["panama"],
        "PE": ["peru"],
        "PL": ["poland", "polska"],
        "PT": ["portugal"],
        "QA": ["qatar"],
        "RS": ["serbia"],
        "RU": ["russia"],
        "SA": ["saudi arabia"],
        "SE": ["sweden"],
        "SN": ["senegal"],
        "TN": ["tunisia"],
        "TR": ["turkey", "turkiye", "türkiye"],
        "AE": ["united arab emirates", "uae", "u.a.e."],
        "US": ["usa", "u.s.a.", "us", "u.s.", "united states", "united states of america", "america"],
        "UY": ["uruguay"],
        "UZ": ["uzbekistan"],
        "ZA": ["south africa"]
    ]

    private static let regionCodeByAlias: [String: String] = {
        aliasesByRegionCode.reduce(into: [String: String]()) { result, entry in
            for alias in entry.value {
                result[normalize(alias)] = entry.key
            }
        }
    }()

    private static let regionCodeByProviderCode: [String: String] = [
        "COD": "CD",
        "CIV": "CI",
        "CZE": "CZ",
        "CUW": "CW",
        "ENG": "GB",
        "GER": "DE",
        "KOR": "KR",
        "MEX": "MX",
        "NED": "NL",
        "NIR": "GB",
        "PRK": "KP",
        "SCO": "GB",
        "UAE": "AE",
        "USA": "US",
        "WAL": "GB"
    ]

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
        if let mappedCode = regionCodeByProviderCode[uppercasedCode] {
            return mappedCode
        }
        if aliasesByRegionCode.keys.contains(uppercasedCode) {
            return uppercasedCode
        }

        let normalized = normalize(teamName)
        guard !normalized.isEmpty else { return nil }
        if let direct = regionCodeByAlias[normalized] {
            return direct
        }
        if let withoutTeamSuffix = normalizedCountryTeamSuffixRemoved(normalized),
           let direct = regionCodeByAlias[withoutTeamSuffix] {
            return direct
        }
        return regionCodeByAlias.first { alias, _ in
            normalized == alias || normalized.hasSuffix(" \(alias)")
        }?.value
    }

    private static func normalizedCountryTeamSuffixRemoved(_ normalized: String) -> String? {
        let suffixes = [
            " women",
            " men",
            " womens",
            " mens",
            " u17",
            " u18",
            " u19",
            " u20",
            " u21",
            " u23"
        ]
        guard let suffix = suffixes.first(where: { normalized.hasSuffix($0) }) else { return nil }
        let trimmed = String(normalized.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
