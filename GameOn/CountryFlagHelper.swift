import Foundation

nonisolated enum CountryFlagHelper {
    private struct NationalTeamFlagEntry {
        let code: String
        let names: [String]
        let providerCodes: [String]
    }

    private static let subdivisionFlags: [(aliases: [String], flag: String)] = [
        (["england"], "\u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}"),
        (["scotland"], "\u{1F3F4}\u{E0067}\u{E0062}\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}"),
        (["wales"], "\u{1F3F4}\u{E0067}\u{E0062}\u{E0077}\u{E006C}\u{E0073}"),
        (["northern ireland"], "\u{1F1EC}\u{1F1E7}"),
    ]

    private static let entries: [NationalTeamFlagEntry] = [
        // North America
        NationalTeamFlagEntry(code: "US", names: ["United States", "United States of America", "America"], providerCodes: ["USA"]),
        NationalTeamFlagEntry(code: "MX", names: ["Mexico", "México"], providerCodes: ["MEX"]),
        NationalTeamFlagEntry(code: "CA", names: ["Canada"], providerCodes: ["CAN"]),
        NationalTeamFlagEntry(code: "CR", names: ["Costa Rica"], providerCodes: ["CRC"]),
        NationalTeamFlagEntry(code: "CW", names: ["Curaçao", "Curacao"], providerCodes: ["CUW"]),
        NationalTeamFlagEntry(code: "JM", names: ["Jamaica"], providerCodes: ["JAM"]),
        NationalTeamFlagEntry(code: "PA", names: ["Panama"], providerCodes: ["PAN"]),
        NationalTeamFlagEntry(code: "HN", names: ["Honduras"], providerCodes: ["HON"]),
        NationalTeamFlagEntry(code: "SV", names: ["El Salvador"], providerCodes: ["SLV"]),
        NationalTeamFlagEntry(code: "GT", names: ["Guatemala"], providerCodes: ["GUA"]),
        NationalTeamFlagEntry(code: "HT", names: ["Haiti"], providerCodes: ["HAI"]),
        NationalTeamFlagEntry(code: "TT", names: ["Trinidad and Tobago"], providerCodes: ["TRI"]),
        NationalTeamFlagEntry(code: "CU", names: ["Cuba"], providerCodes: ["CUB"]),
        // South America
        NationalTeamFlagEntry(code: "BR", names: ["Brazil", "Brasil"], providerCodes: ["BRA"]),
        NationalTeamFlagEntry(code: "AR", names: ["Argentina"], providerCodes: ["ARG"]),
        NationalTeamFlagEntry(code: "CO", names: ["Colombia"], providerCodes: ["COL"]),
        NationalTeamFlagEntry(code: "UY", names: ["Uruguay"], providerCodes: ["URU"]),
        NationalTeamFlagEntry(code: "CL", names: ["Chile"], providerCodes: ["CHI"]),
        NationalTeamFlagEntry(code: "PE", names: ["Peru", "Perú"], providerCodes: ["PER"]),
        NationalTeamFlagEntry(code: "EC", names: ["Ecuador"], providerCodes: ["ECU"]),
        NationalTeamFlagEntry(code: "PY", names: ["Paraguay"], providerCodes: ["PAR"]),
        NationalTeamFlagEntry(code: "BO", names: ["Bolivia"], providerCodes: ["BOL"]),
        NationalTeamFlagEntry(code: "VE", names: ["Venezuela"], providerCodes: ["VEN"]),
        // Europe
        NationalTeamFlagEntry(code: "GB", names: ["Great Britain", "Britain", "United Kingdom", "UK"], providerCodes: ["GBR"]),
        NationalTeamFlagEntry(code: "FR", names: ["France"], providerCodes: ["FRA"]),
        NationalTeamFlagEntry(code: "ES", names: ["Spain", "España"], providerCodes: ["ESP"]),
        NationalTeamFlagEntry(code: "DE", names: ["Germany", "Deutschland"], providerCodes: ["GER"]),
        NationalTeamFlagEntry(code: "IT", names: ["Italy", "Italia"], providerCodes: ["ITA"]),
        NationalTeamFlagEntry(code: "PT", names: ["Portugal"], providerCodes: ["POR"]),
        NationalTeamFlagEntry(code: "NL", names: ["Netherlands", "Holland"], providerCodes: ["NED"]),
        NationalTeamFlagEntry(code: "BE", names: ["Belgium", "België", "Belgique"], providerCodes: ["BEL"]),
        NationalTeamFlagEntry(code: "HR", names: ["Croatia", "Hrvatska"], providerCodes: ["CRO"]),
        NationalTeamFlagEntry(code: "CH", names: ["Switzerland", "Swiss"], providerCodes: ["SUI"]),
        NationalTeamFlagEntry(code: "DK", names: ["Denmark"], providerCodes: ["DEN"]),
        NationalTeamFlagEntry(code: "SE", names: ["Sweden"], providerCodes: ["SWE"]),
        NationalTeamFlagEntry(code: "NO", names: ["Norway"], providerCodes: ["NOR"]),
        NationalTeamFlagEntry(code: "PL", names: ["Poland", "Polska"], providerCodes: ["POL"]),
        NationalTeamFlagEntry(code: "RS", names: ["Serbia"], providerCodes: ["SRB"]),
        NationalTeamFlagEntry(code: "TR", names: ["Turkey", "Turkiye", "Türkiye"], providerCodes: ["TUR"]),
        NationalTeamFlagEntry(code: "UA", names: ["Ukraine"], providerCodes: ["UKR"]),
        NationalTeamFlagEntry(code: "AT", names: ["Austria", "Österreich"], providerCodes: ["AUT"]),
        NationalTeamFlagEntry(code: "CZ", names: ["Czech Republic", "Czechia", "Czech"], providerCodes: ["CZE"]),
        NationalTeamFlagEntry(code: "HU", names: ["Hungary"], providerCodes: ["HUN"]),
        NationalTeamFlagEntry(code: "RO", names: ["Romania"], providerCodes: ["ROU"]),
        NationalTeamFlagEntry(code: "IE", names: ["Ireland", "Republic of Ireland"], providerCodes: ["IRL"]),
        NationalTeamFlagEntry(code: "FI", names: ["Finland"], providerCodes: ["FIN"]),
        NationalTeamFlagEntry(code: "GR", names: ["Greece"], providerCodes: ["GRE"]),
        NationalTeamFlagEntry(code: "SK", names: ["Slovakia"], providerCodes: ["SVK"]),
        NationalTeamFlagEntry(code: "SI", names: ["Slovenia"], providerCodes: ["SVN"]),
        NationalTeamFlagEntry(code: "BA", names: ["Bosnia and Herzegovina", "Bosnia"], providerCodes: ["BIH"]),
        NationalTeamFlagEntry(code: "AL", names: ["Albania"], providerCodes: ["ALB"]),
        NationalTeamFlagEntry(code: "IS", names: ["Iceland"], providerCodes: ["ISL"]),
        NationalTeamFlagEntry(code: "MK", names: ["North Macedonia", "Macedonia"], providerCodes: ["MKD"]),
        NationalTeamFlagEntry(code: "ME", names: ["Montenegro"], providerCodes: ["MNE"]),
        NationalTeamFlagEntry(code: "BG", names: ["Bulgaria"], providerCodes: ["BUL"]),
        // Africa
        NationalTeamFlagEntry(code: "MA", names: ["Morocco"], providerCodes: ["MAR"]),
        NationalTeamFlagEntry(code: "SN", names: ["Senegal"], providerCodes: ["SEN"]),
        NationalTeamFlagEntry(code: "NG", names: ["Nigeria"], providerCodes: ["NGA"]),
        NationalTeamFlagEntry(code: "GH", names: ["Ghana"], providerCodes: ["GHA"]),
        NationalTeamFlagEntry(code: "CM", names: ["Cameroon"], providerCodes: ["CMR"]),
        NationalTeamFlagEntry(code: "CI", names: ["Ivory Coast", "Côte d'Ivoire", "Cote d'Ivoire"], providerCodes: ["CIV"]),
        NationalTeamFlagEntry(code: "EG", names: ["Egypt"], providerCodes: ["EGY"]),
        NationalTeamFlagEntry(code: "TN", names: ["Tunisia"], providerCodes: ["TUN"]),
        NationalTeamFlagEntry(code: "DZ", names: ["Algeria", "Algérie", "Algerie"], providerCodes: ["ALG", "DZA"]),
        NationalTeamFlagEntry(code: "ZA", names: ["South Africa"], providerCodes: ["RSA"]),
        NationalTeamFlagEntry(code: "ML", names: ["Mali"], providerCodes: ["MLI"]),
        NationalTeamFlagEntry(code: "CD", names: ["DR Congo", "D.R. Congo", "Congo DR", "Congo DR", "Democratic Republic of Congo", "Congo Kinshasa", "Congo-Kinshasa"], providerCodes: ["COD"]),
        NationalTeamFlagEntry(code: "BF", names: ["Burkina Faso"], providerCodes: ["BFA"]),
        NationalTeamFlagEntry(code: "CV", names: ["Cape Verde", "Cabo Verde"], providerCodes: ["CPV"]),
        NationalTeamFlagEntry(code: "GN", names: ["Guinea"], providerCodes: ["GUI"]),
        NationalTeamFlagEntry(code: "AO", names: ["Angola"], providerCodes: ["ANG"]),
        NationalTeamFlagEntry(code: "JO", names: ["Jordan"], providerCodes: ["JOR"]),
        // Asia & Oceania
        NationalTeamFlagEntry(code: "JP", names: ["Japan"], providerCodes: ["JPN"]),
        NationalTeamFlagEntry(code: "KR", names: ["South Korea", "Korea Republic", "Republic of Korea", "Korea"], providerCodes: ["KOR"]),
        NationalTeamFlagEntry(code: "KP", names: ["North Korea", "Korea DPR", "DPR Korea"], providerCodes: ["PRK"]),
        NationalTeamFlagEntry(code: "SA", names: ["Saudi Arabia"], providerCodes: ["KSA"]),
        NationalTeamFlagEntry(code: "AU", names: ["Australia"], providerCodes: ["AUS"]),
        NationalTeamFlagEntry(code: "IR", names: ["Iran"], providerCodes: ["IRN"]),
        NationalTeamFlagEntry(code: "QA", names: ["Qatar"], providerCodes: ["QAT"]),
        NationalTeamFlagEntry(code: "AE", names: ["United Arab Emirates", "UAE", "U.A.E."], providerCodes: ["UAE"]),
        NationalTeamFlagEntry(code: "IQ", names: ["Iraq"], providerCodes: ["IRQ"]),
        NationalTeamFlagEntry(code: "UZ", names: ["Uzbekistan"], providerCodes: ["UZB"]),
        NationalTeamFlagEntry(code: "CN", names: ["China", "PR China"], providerCodes: ["CHN"]),
        NationalTeamFlagEntry(code: "ID", names: ["Indonesia"], providerCodes: ["IDN"]),
        NationalTeamFlagEntry(code: "NZ", names: ["New Zealand"], providerCodes: ["NZL"]),
        NationalTeamFlagEntry(code: "FJ", names: ["Fiji"], providerCodes: ["FIJ"]),
        NationalTeamFlagEntry(code: "PF", names: ["Tahiti", "French Polynesia"], providerCodes: ["TAH"]),
        NationalTeamFlagEntry(code: "SB", names: ["Solomon Islands"], providerCodes: ["SOL"]),
        NationalTeamFlagEntry(code: "IN", names: ["India"], providerCodes: ["IND"]),
        NationalTeamFlagEntry(code: "TH", names: ["Thailand"], providerCodes: ["THA"]),
        NationalTeamFlagEntry(code: "VN", names: ["Vietnam", "Viet Nam"], providerCodes: ["VIE"]),
    ]

    private static let aliasesByRegionCode: [String: [String]] = {
        entries.reduce(into: [String: [String]]()) { result, entry in
            result[entry.code] = entry.names
        }
    }()

    private static let regionCodeByAlias: [String: String] = {
        var result = [String: String]()
        for entry in entries {
            for name in entry.names {
                result[normalize(name)] = entry.code
            }
        }
        for group in subdivisionFlags {
            for alias in group.aliases where result[alias] == nil {
                result[alias] = "GB"
            }
        }
        return result
    }()

    private static let regionCodeByProviderCode: [String: String] = {
        var result: [String: String] = [
            "ENG": "GB",
            "NIR": "GB",
            "SCO": "GB",
            "WAL": "GB",
        ]
        for entry in entries {
            for providerCode in entry.providerCodes {
                result[providerCode.uppercased()] = entry.code
            }
        }
        return result
    }()

    private static let subdivisionFlagByAlias: [String: String] = {
        subdivisionFlags.reduce(into: [String: String]()) { result, group in
            for alias in group.aliases {
                result[alias] = group.flag
            }
        }
    }()

    #if DEBUG
    nonisolated(unsafe) private static var loggedMissingFlags = Set<String>()
    nonisolated(unsafe) private static var didValidateWorldCupTeams = false
    #endif

    static func flag(for teamName: String, source: String? = nil) -> String? {
        #if DEBUG
        validateWorldCupTeamsIfNeeded()
        #endif

        let trimmed = teamName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let normalized = normalize(trimmed)
        if let subdivisionFlag = subdivisionFlagByAlias[normalized] {
            return subdivisionFlag
        }

        guard let regionCode = regionCode(for: trimmed) else {
            logMissingFlag(rawName: trimmed, source: source)
            return nil
        }
        return flagEmoji(forRegionCode: regionCode)
    }

    static func countryCode(for teamName: String) -> String? {
        regionCode(for: teamName)
    }

    static func isCountry(_ teamName: String) -> Bool {
        regionCode(for: teamName) != nil
    }

    @MainActor
    static func displayName(for teamName: String, languageCode: String? = nil) -> String {
        let trimmed = teamName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let normalized = normalize(trimmed)
        if subdivisionFlagByAlias[normalized] != nil {
            return trimmed
        }

        guard let regionCode = regionCode(for: trimmed) else {
            return trimmed
        }
        let localeIdentifier = L10n.normalizedLanguageCode(languageCode ?? UserDefaults.standard.string(forKey: L10n.appLanguageKey))
        let localized = Locale(identifier: localeIdentifier).localizedString(forRegionCode: regionCode)
        let trimmedLocalized = localized?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedLocalized.isEmpty ? trimmed : trimmedLocalized
    }

    @MainActor
    static func countrySuggestions(matching query: String, languageCode: String? = nil) -> [(name: String, code: String, flag: String)] {
        let normalizedQuery = normalize(query)
        let localeIdentifier = L10n.normalizedLanguageCode(languageCode ?? UserDefaults.standard.string(forKey: L10n.appLanguageKey))
        return entries.compactMap { entry in
            let localized = Locale(identifier: localeIdentifier).localizedString(forRegionCode: entry.code) ?? entry.code
            let aliases = entry.names
            guard normalizedQuery.isEmpty
                    || normalize(localized).contains(normalizedQuery)
                    || aliases.contains(where: { normalize($0).contains(normalizedQuery) }) else {
                return nil
            }
            return (name: localized, code: entry.code, flag: flagEmoji(forRegionCode: entry.code))
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    #if DEBUG
    static func validateWorldCupTeams(source: String = "CountryFlagHelperValidation") -> [String] {
        var missing: [String] = []
        for team in CountryFlagHelperWorldCupValidation.teams {
            if flag(for: team, source: source) == nil {
                missing.append(team)
            }
        }
        if missing.isEmpty {
            print("[CountryFlagDebug] worldCupValidation=passed count=\(CountryFlagHelperWorldCupValidation.teams.count)")
        } else {
            print("[CountryFlagDebug] worldCupValidation=failed missingCount=\(missing.count) missing=\(missing.joined(separator: ", "))")
        }
        return missing
    }
    #endif

    private static func regionCode(for teamName: String) -> String? {
        let trimmed = teamName.trimmingCharacters(in: .whitespacesAndNewlines)
        let uppercasedCode = trimmed.uppercased()
        if let mappedCode = regionCodeByProviderCode[uppercasedCode] {
            return mappedCode
        }
        if aliasesByRegionCode.keys.contains(uppercasedCode) {
            return uppercasedCode
        }

        let normalized = normalize(trimmed)
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
            " u23",
            " national team",
            " nt",
        ]
        guard let suffix = suffixes.first(where: { normalized.hasSuffix($0) }) else { return nil }
        let trimmed = String(normalized.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalize(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "'", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func logMissingFlag(rawName: String, source: String?) {
        #if DEBUG
        let normalizedName = normalize(rawName)
        let key = "\(normalizedName)|\(source ?? "unspecified")"
        guard loggedMissingFlags.insert(key).inserted else { return }
        print("[CountryFlagDebug] missingFlagFor=\(rawName)")
        print("[CountryFlagDebug] normalizedName=\(normalizedName)")
        print("[CountryFlagDebug] source=\(source ?? "unspecified")")
        #else
        _ = rawName
        _ = source
        #endif
    }

    #if DEBUG
    private static func validateWorldCupTeamsIfNeeded() {
        guard !didValidateWorldCupTeams else { return }
        didValidateWorldCupTeams = true
        _ = validateWorldCupTeams()
    }
    #endif

    static func flagEmoji(forRegionCode regionCode: String) -> String {
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

#if DEBUG
nonisolated enum CountryFlagHelperWorldCupValidation {
    /// National teams used across saved Pro games, favorites, predictions, and World Cup 2026 flows.
    static let teams: [String] = [
        "Algeria",
        "Angola",
        "Argentina",
        "Australia",
        "Austria",
        "Belgium",
        "Bolivia",
        "Brazil",
        "Burkina Faso",
        "Cameroon",
        "Canada",
        "Cape Verde",
        "Chile",
        "China",
        "Colombia",
        "Costa Rica",
        "Côte d'Ivoire",
        "Croatia",
        "Curaçao",
        "Curacao",
        "Czech Republic",
        "Czechia",
        "DR Congo",
        "Denmark",
        "Ecuador",
        "Egypt",
        "England",
        "France",
        "Germany",
        "Ghana",
        "Guinea",
        "Haiti",
        "Iran",
        "Iraq",
        "Italy",
        "Ivory Coast",
        "Jamaica",
        "Japan",
        "Jordan",
        "Korea Republic",
        "Mali",
        "Mexico",
        "Morocco",
        "Netherlands",
        "New Zealand",
        "Northern Ireland",
        "Norway",
        "Panama",
        "Paraguay",
        "Peru",
        "Poland",
        "Portugal",
        "Qatar",
        "Romania",
        "Saudi Arabia",
        "Scotland",
        "Senegal",
        "Serbia",
        "South Africa",
        "South Korea",
        "Spain",
        "Switzerland",
        "Tunisia",
        "Turkey",
        "United States",
        "Uruguay",
        "USA",
        "Uzbekistan",
        "Venezuela",
        "Wales",
    ]
}
#endif
