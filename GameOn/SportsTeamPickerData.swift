import Foundation

enum TeamPickerSport: String, Hashable {
    case soccer
    case basketball
    case baseball
    case hockey
    case football
    case other

    static func resolve(_ sportName: String) -> TeamPickerSport {
        let lowered = sportName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowered.contains("soccer") { return .soccer }
        if lowered.contains("basketball") || lowered == "nba" || lowered == "wnba" { return .basketball }
        if lowered.contains("baseball") || lowered == "mlb" { return .baseball }
        if lowered.contains("hockey") || lowered == "nhl" { return .hockey }
        if lowered.contains("football") || lowered == "nfl" { return .football }
        return .other
    }
}

enum TeamPickerMode: String, CaseIterable, Identifiable {
    case countries = "Countries"
    case teams = "Teams"

    var id: String { rawValue }
}

struct TeamPickerOption: Identifiable, Hashable {
    let id: String
    let displayName: String
    let shortName: String?
    let sport: TeamPickerSport
    let mode: TeamPickerMode
    let region: String
    let leagueGroup: String
    let emoji: String?
    let themeHint: String?

    var searchableText: String {
        [
            displayName,
            shortName ?? "",
            sport.rawValue,
            mode.rawValue,
            region,
            leagueGroup,
            themeHint ?? ""
        ]
        .joined(separator: " ")
    }
}

struct TeamPickerGroup: Identifiable, Hashable {
    let id: String
    let title: String
    let options: [TeamPickerOption]
}

struct TeamPickerRegionGroup: Identifiable, Hashable {
    let id: String
    let title: String
    let groups: [TeamPickerGroup]
}

enum SportsTeamPickerData {
    /// Canonical country/team options used by business game management. Fan favorite picking reuses this
    /// so both flows speak the same sports identity vocabulary without adding network calls.
    static var favoriteCatalogOptions: [TeamPickerOption] {
        allOptions
    }

    static func preferredMode(for sportName: String) -> TeamPickerMode {
        TeamPickerSport.resolve(sportName) == .soccer ? .countries : .teams
    }

    static func regionGroups(
        sportName: String,
        mode: TeamPickerMode,
        query: String
    ) -> [TeamPickerRegionGroup] {
        let sport = TeamPickerSport.resolve(sportName)
        let q = normalize(query)
        let filtered = allOptions.filter { option in
            option.sport == sport
                && option.mode == mode
                && (q.isEmpty || normalize(option.searchableText).contains(q))
        }
        return grouped(filtered, sport: sport)
    }

    static func exactOption(named raw: String) -> TeamPickerOption? {
        let normalized = normalize(raw)
        guard !normalized.isEmpty else { return nil }
        return allOptions.first { option in
            normalize(option.displayName) == normalized
                || option.shortName.map(normalize) == normalized
        }
    }

    private static func grouped(_ options: [TeamPickerOption], sport: TeamPickerSport) -> [TeamPickerRegionGroup] {
        let regionBuckets = Dictionary(grouping: options, by: \.region)
        return regionBuckets.map { region, regionOptions in
            let leagueBuckets = Dictionary(grouping: regionOptions, by: \.leagueGroup)
            let groups = leagueBuckets.map { league, leagueOptions in
                TeamPickerGroup(
                    id: "\(region)-\(league)".pickerID,
                    title: league,
                    options: leagueOptions.sorted { lhs, rhs in
                        lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
                    }
                )
            }
            .sorted { lhs, rhs in
                let order = leagueOrder(for: sport, region: region)
                let left = order.firstIndex(of: lhs.title) ?? Int.max
                let right = order.firstIndex(of: rhs.title) ?? Int.max
                if left != right { return left < right }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            return TeamPickerRegionGroup(id: region.pickerID, title: region, groups: groups)
        }
        .sorted { lhs, rhs in
            let order = regionOrder(for: sport)
            let left = order.firstIndex(of: lhs.title) ?? Int.max
            let right = order.firstIndex(of: rhs.title) ?? Int.max
            if left != right { return left < right }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private static func regionOrder(for sport: TeamPickerSport) -> [String] {
        switch sport {
        case .soccer:
            return ["North America", "South America", "Europe", "Africa", "Asia", "Oceania"]
        case .basketball:
            return ["NBA", "WNBA", "College Basketball", "International"]
        case .baseball:
            return ["MLB", "International"]
        case .hockey:
            return ["NHL", "International"]
        case .football:
            return ["NFL", "College Football"]
        case .other:
            return []
        }
    }

    private static func leagueOrder(for sport: TeamPickerSport, region: String) -> [String] {
        switch (sport, region) {
        case (.soccer, "North America"):
            return ["MLS", "Liga MX", "CONCACAF national teams"]
        case (.soccer, "South America"):
            return ["Brazil Serie A", "Argentina Primera Division", "CONMEBOL national teams"]
        case (.soccer, "Europe"):
            return ["Premier League", "La Liga", "Serie A", "Bundesliga", "Ligue 1", "Primeira Liga", "Eredivisie", "Scottish Premiership", "UEFA national teams"]
        case (.soccer, "Africa"):
            return ["CAF national teams"]
        case (.soccer, "Asia"):
            return ["J1 League", "Saudi Pro League", "K League", "Asian national teams"]
        case (.soccer, "Oceania"):
            return ["OFC national teams"]
        case (.basketball, "NBA"):
            return ["Eastern Conference", "Western Conference"]
        case (.basketball, "WNBA"):
            return ["WNBA"]
        case (.basketball, "College Basketball"):
            return ["SEC", "Big Ten", "ACC", "Big 12", "Pac-12", "AAC", "Big East"]
        case (.basketball, "International"):
            return ["International / national teams"]
        case (.baseball, "MLB"):
            return ["American League East", "American League Central", "American League West", "National League East", "National League Central", "National League West"]
        case (.baseball, "International"):
            return ["International / national teams"]
        case (.hockey, "NHL"):
            return ["Eastern Conference", "Western Conference"]
        case (.hockey, "International"):
            return ["International / national teams"]
        case (.football, "NFL"):
            return ["AFC East", "AFC North", "AFC South", "AFC West", "NFC East", "NFC North", "NFC South", "NFC West"]
        case (.football, "College Football"):
            return ["SEC", "Big Ten", "ACC", "Big 12", "Pac-12", "AAC"]
        default:
            return []
        }
    }

    nonisolated private static func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }

    private static func country(
        _ id: String,
        _ name: String,
        _ sport: TeamPickerSport,
        _ region: String,
        _ group: String,
        code: String? = nil,
        short: String? = nil
    ) -> TeamPickerOption {
        TeamPickerOption(
            id: "\(sport.rawValue)-country-\(id)",
            displayName: name,
            shortName: short,
            sport: sport,
            mode: .countries,
            region: region,
            leagueGroup: group,
            emoji: (code ?? CountryFlagHelper.countryCode(for: name)).map { flagEmoji(forRegionCode: $0) },
            themeHint: code
        )
    }

    private static func team(
        _ id: String,
        _ name: String,
        _ sport: TeamPickerSport,
        _ region: String,
        _ group: String,
        short: String? = nil,
        icon: String? = nil,
        theme: String? = nil
    ) -> TeamPickerOption {
        TeamPickerOption(
            id: "\(sport.rawValue)-team-\(id)",
            displayName: name,
            shortName: short,
            sport: sport,
            mode: .teams,
            region: region,
            leagueGroup: group,
            emoji: icon,
            themeHint: theme
        )
    }

    private static func teamList(
        _ sport: TeamPickerSport,
        _ region: String,
        _ group: String,
        icon: String,
        _ items: [(String, String, String)]
    ) -> [TeamPickerOption] {
        items.map { id, name, short in
            team(id, name, sport, region, group, short: short, icon: icon)
        }
    }

    private static let allOptions: [TeamPickerOption] = soccerCountries + soccerTeams + basketballCountries + basketballTeams + baseballCountries + baseballTeams + hockeyCountries + hockeyTeams + footballTeams

    private static let soccerCountries: [TeamPickerOption] = [
        country("usa", "United States", .soccer, "North America", "CONCACAF national teams", code: "US", short: "USA"),
        country("mexico", "Mexico", .soccer, "North America", "CONCACAF national teams", code: "MX"),
        country("canada", "Canada", .soccer, "North America", "CONCACAF national teams", code: "CA"),
        country("costa-rica", "Costa Rica", .soccer, "North America", "CONCACAF national teams", code: "CR"),
        country("jamaica", "Jamaica", .soccer, "North America", "CONCACAF national teams", code: "JM"),
        country("panama", "Panama", .soccer, "North America", "CONCACAF national teams", code: "PA"),
        country("honduras", "Honduras", .soccer, "North America", "CONCACAF national teams", code: "HN"),
        country("el-salvador", "El Salvador", .soccer, "North America", "CONCACAF national teams", code: "SV"),
        country("guatemala", "Guatemala", .soccer, "North America", "CONCACAF national teams", code: "GT"),
        country("haiti", "Haiti", .soccer, "North America", "CONCACAF national teams", code: "HT"),
        country("trinidad-tobago", "Trinidad and Tobago", .soccer, "North America", "CONCACAF national teams", code: "TT"),
        country("brazil", "Brazil", .soccer, "South America", "CONMEBOL national teams", code: "BR"),
        country("argentina", "Argentina", .soccer, "South America", "CONMEBOL national teams", code: "AR"),
        country("colombia", "Colombia", .soccer, "South America", "CONMEBOL national teams", code: "CO"),
        country("uruguay", "Uruguay", .soccer, "South America", "CONMEBOL national teams", code: "UY"),
        country("chile", "Chile", .soccer, "South America", "CONMEBOL national teams", code: "CL"),
        country("peru", "Peru", .soccer, "South America", "CONMEBOL national teams", code: "PE"),
        country("ecuador", "Ecuador", .soccer, "South America", "CONMEBOL national teams", code: "EC"),
        country("paraguay", "Paraguay", .soccer, "South America", "CONMEBOL national teams", code: "PY"),
        country("bolivia", "Bolivia", .soccer, "South America", "CONMEBOL national teams", code: "BO"),
        country("venezuela", "Venezuela", .soccer, "South America", "CONMEBOL national teams", code: "VE"),
        country("england", "England", .soccer, "Europe", "UEFA national teams", code: "GB"),
        country("france", "France", .soccer, "Europe", "UEFA national teams", code: "FR"),
        country("spain", "Spain", .soccer, "Europe", "UEFA national teams", code: "ES"),
        country("germany", "Germany", .soccer, "Europe", "UEFA national teams", code: "DE"),
        country("italy", "Italy", .soccer, "Europe", "UEFA national teams", code: "IT"),
        country("portugal", "Portugal", .soccer, "Europe", "UEFA national teams", code: "PT"),
        country("netherlands", "Netherlands", .soccer, "Europe", "UEFA national teams", code: "NL"),
        country("belgium", "Belgium", .soccer, "Europe", "UEFA national teams", code: "BE"),
        country("croatia", "Croatia", .soccer, "Europe", "UEFA national teams", code: "HR"),
        country("switzerland", "Switzerland", .soccer, "Europe", "UEFA national teams", code: "CH"),
        country("denmark", "Denmark", .soccer, "Europe", "UEFA national teams", code: "DK"),
        country("sweden", "Sweden", .soccer, "Europe", "UEFA national teams", code: "SE"),
        country("norway", "Norway", .soccer, "Europe", "UEFA national teams", code: "NO"),
        country("poland", "Poland", .soccer, "Europe", "UEFA national teams", code: "PL"),
        country("serbia", "Serbia", .soccer, "Europe", "UEFA national teams", code: "RS"),
        country("turkey", "Turkey", .soccer, "Europe", "UEFA national teams", code: "TR"),
        country("scotland", "Scotland", .soccer, "Europe", "UEFA national teams", code: "GB"),
        country("wales", "Wales", .soccer, "Europe", "UEFA national teams", code: "GB"),
        country("ukraine", "Ukraine", .soccer, "Europe", "UEFA national teams", code: "UA"),
        country("austria", "Austria", .soccer, "Europe", "UEFA national teams", code: "AT"),
        country("czechia", "Czechia", .soccer, "Europe", "UEFA national teams", code: "CZ"),
        country("hungary", "Hungary", .soccer, "Europe", "UEFA national teams", code: "HU"),
        country("romania", "Romania", .soccer, "Europe", "UEFA national teams", code: "RO"),
        country("ireland", "Ireland", .soccer, "Europe", "UEFA national teams", code: "IE"),
        country("morocco", "Morocco", .soccer, "Africa", "CAF national teams", code: "MA"),
        country("senegal", "Senegal", .soccer, "Africa", "CAF national teams", code: "SN"),
        country("nigeria", "Nigeria", .soccer, "Africa", "CAF national teams", code: "NG"),
        country("ghana", "Ghana", .soccer, "Africa", "CAF national teams", code: "GH"),
        country("cameroon", "Cameroon", .soccer, "Africa", "CAF national teams", code: "CM"),
        country("ivory-coast", "Ivory Coast", .soccer, "Africa", "CAF national teams", code: "CI"),
        country("egypt", "Egypt", .soccer, "Africa", "CAF national teams", code: "EG"),
        country("tunisia", "Tunisia", .soccer, "Africa", "CAF national teams", code: "TN"),
        country("algeria", "Algeria", .soccer, "Africa", "CAF national teams", code: "DZ"),
        country("south-africa", "South Africa", .soccer, "Africa", "CAF national teams", code: "ZA"),
        country("mali", "Mali", .soccer, "Africa", "CAF national teams", code: "ML"),
        country("dr-congo", "DR Congo", .soccer, "Africa", "CAF national teams", code: "CD"),
        country("burkina-faso", "Burkina Faso", .soccer, "Africa", "CAF national teams", code: "BF"),
        country("cape-verde", "Cape Verde", .soccer, "Africa", "CAF national teams", code: "CV"),
        country("guinea", "Guinea", .soccer, "Africa", "CAF national teams", code: "GN"),
        country("angola", "Angola", .soccer, "Africa", "CAF national teams", code: "AO"),
        country("japan", "Japan", .soccer, "Asia", "Asian national teams", code: "JP"),
        country("south-korea", "South Korea", .soccer, "Asia", "Asian national teams", code: "KR"),
        country("saudi-arabia", "Saudi Arabia", .soccer, "Asia", "Asian national teams", code: "SA"),
        country("australia", "Australia", .soccer, "Asia", "Asian national teams", code: "AU"),
        country("iran", "Iran", .soccer, "Asia", "Asian national teams", code: "IR"),
        country("qatar", "Qatar", .soccer, "Asia", "Asian national teams", code: "QA"),
        country("uae", "United Arab Emirates", .soccer, "Asia", "Asian national teams", code: "AE", short: "UAE"),
        country("iraq", "Iraq", .soccer, "Asia", "Asian national teams", code: "IQ"),
        country("uzbekistan", "Uzbekistan", .soccer, "Asia", "Asian national teams", code: "UZ"),
        country("china", "China", .soccer, "Asia", "Asian national teams", code: "CN"),
        country("indonesia", "Indonesia", .soccer, "Asia", "Asian national teams", code: "ID"),
        country("new-zealand", "New Zealand", .soccer, "Oceania", "OFC national teams", code: "NZ"),
        country("fiji", "Fiji", .soccer, "Oceania", "OFC national teams", code: "FJ"),
        country("tahiti", "Tahiti", .soccer, "Oceania", "OFC national teams", code: "PF"),
        country("solomon-islands", "Solomon Islands", .soccer, "Oceania", "OFC national teams", code: "SB")
    ]

    private static let soccerTeams: [TeamPickerOption] =
        teamList(.soccer, "North America", "MLS", icon: "⚽", [
            ("atlanta-united", "Atlanta United", "ATL"), ("austin-fc", "Austin FC", "ATX"), ("charlotte-fc", "Charlotte FC", "CLT"), ("chicago-fire", "Chicago Fire", "CHI"), ("fc-cincinnati", "FC Cincinnati", "CIN"),
            ("colorado-rapids", "Colorado Rapids", "COL"), ("columbus-crew", "Columbus Crew", "CLB"), ("dc-united", "D.C. United", "DC"), ("fc-dallas", "FC Dallas", "DAL"), ("houston-dynamo", "Houston Dynamo", "HOU"),
            ("sporting-kc", "Sporting Kansas City", "SKC"), ("la-galaxy", "LA Galaxy", "LAG"), ("lafc", "LAFC", "LAFC"), ("inter-miami", "Inter Miami", "MIA"), ("minnesota-united", "Minnesota United", "MIN"),
            ("cf-montreal", "CF Montreal", "MTL"), ("nashville-sc", "Nashville SC", "NSH"), ("new-england", "New England Revolution", "NE"), ("nycfc", "New York City FC", "NYC"), ("ny-red-bulls", "New York Red Bulls", "RBNY"),
            ("orlando-city", "Orlando City", "ORL"), ("philadelphia-union", "Philadelphia Union", "PHI"), ("portland-timbers", "Portland Timbers", "POR"), ("real-salt-lake", "Real Salt Lake", "RSL"), ("san-diego-fc", "San Diego FC", "SD"),
            ("san-jose", "San Jose Earthquakes", "SJ"), ("seattle-sounders", "Seattle Sounders", "SEA"), ("st-louis-city", "St. Louis CITY SC", "STL"), ("toronto-fc", "Toronto FC", "TOR"), ("vancouver-whitecaps", "Vancouver Whitecaps", "VAN")
        ])
        + teamList(.soccer, "North America", "Liga MX", icon: "⚽", [
            ("club-america", "Club America", "AME"), ("chivas", "Chivas", "GDL"), ("tigres", "Tigres", "TIG"), ("monterrey", "Monterrey", "MTY"), ("pumas", "Pumas", "PUM"),
            ("cruz-azul", "Cruz Azul", "CAZ"), ("toluca", "Toluca", "TOL"), ("leon", "Leon", "LEO"), ("pachuca", "Pachuca", "PAC"), ("santos-laguna", "Santos Laguna", "SAN"),
            ("atlas", "Atlas", "ATS"), ("necaxa", "Necaxa", "NEC"), ("tijuana", "Tijuana", "TIJ"), ("queretaro", "Queretaro", "QRO"), ("puebla", "Puebla", "PUE"),
            ("mazatlan", "Mazatlan", "MAZ"), ("fc-juarez", "FC Juarez", "JUA"), ("atletico-san-luis", "Atletico San Luis", "ASL")
        ])
        + teamList(.soccer, "South America", "Brazil Serie A", icon: "⚽", [
            ("flamengo", "Flamengo", "FLA"), ("palmeiras", "Palmeiras", "PAL"), ("sao-paulo", "Sao Paulo", "SAO"), ("corinthians", "Corinthians", "COR"), ("fluminense", "Fluminense", "FLU"),
            ("botafogo", "Botafogo", "BOT"), ("vasco", "Vasco da Gama", "VAS"), ("gremio", "Gremio", "GRE"), ("internacional", "Internacional", "INT"), ("atletico-mineiro", "Atletico Mineiro", "CAM")
        ])
        + teamList(.soccer, "South America", "Argentina Primera Division", icon: "⚽", [
            ("boca-juniors", "Boca Juniors", "BOC"), ("river-plate", "River Plate", "RIV"), ("racing-club", "Racing Club", "RAC"), ("independiente", "Independiente", "IND"), ("san-lorenzo", "San Lorenzo", "SLO"),
            ("estudiantes", "Estudiantes", "EST"), ("velez", "Velez Sarsfield", "VEL"), ("rosario-central", "Rosario Central", "ROS")
        ])
        + teamList(.soccer, "South America", "Libertadores-level clubs", icon: "⚽", [
            ("penarol", "Penarol", "PEN"), ("nacional", "Nacional", "NAC"), ("colo-colo", "Colo-Colo", "COL"), ("universidad-chile", "Universidad de Chile", "UCH"), ("atletico-nacional", "Atletico Nacional", "NAL"),
            ("millonarios", "Millonarios", "MIL"), ("ldu-quito", "LDU Quito", "LDU"), ("olimpia", "Olimpia", "OLI")
        ])
        + teamList(.soccer, "Europe", "Premier League", icon: "⚽", [
            ("arsenal", "Arsenal", "ARS"), ("aston-villa", "Aston Villa", "AVL"), ("bournemouth", "Bournemouth", "BOU"), ("brentford", "Brentford", "BRE"), ("brighton", "Brighton", "BHA"),
            ("chelsea", "Chelsea", "CHE"), ("crystal-palace", "Crystal Palace", "CRY"), ("everton", "Everton", "EVE"), ("fulham", "Fulham", "FUL"), ("ipswich", "Ipswich Town", "IPS"),
            ("leicester", "Leicester City", "LEI"), ("liverpool", "Liverpool", "LIV"), ("man-city", "Manchester City", "MCI"), ("man-united", "Manchester United", "MUN"), ("newcastle", "Newcastle United", "NEW"),
            ("nottingham-forest", "Nottingham Forest", "NFO"), ("southampton", "Southampton", "SOU"), ("tottenham", "Tottenham", "TOT"), ("west-ham", "West Ham", "WHU"), ("wolves", "Wolves", "WOL")
        ])
        + teamList(.soccer, "Europe", "La Liga", icon: "⚽", [
            ("real-madrid", "Real Madrid", "RMA"), ("barcelona", "Barcelona", "BAR"), ("atletico-madrid", "Atletico Madrid", "ATM"), ("sevilla", "Sevilla", "SEV"), ("valencia", "Valencia", "VAL"),
            ("villarreal", "Villarreal", "VIL"), ("real-betis", "Real Betis", "BET"), ("real-sociedad", "Real Sociedad", "RSO"), ("athletic-bilbao", "Athletic Bilbao", "ATH"), ("girona", "Girona", "GIR")
        ])
        + teamList(.soccer, "Europe", "Serie A", icon: "⚽", [
            ("juventus", "Juventus", "JUV"), ("ac-milan", "AC Milan", "ACM"), ("inter-milan", "Inter Milan", "INT"), ("napoli", "Napoli", "NAP"), ("roma", "Roma", "ROM"),
            ("lazio", "Lazio", "LAZ"), ("atalanta", "Atalanta", "ATA"), ("fiorentina", "Fiorentina", "FIO"), ("torino", "Torino", "TOR"), ("bologna", "Bologna", "BOL")
        ])
        + teamList(.soccer, "Europe", "Bundesliga", icon: "⚽", [
            ("bayern", "Bayern Munich", "BAY"), ("dortmund", "Borussia Dortmund", "BVB"), ("leverkusen", "Bayer Leverkusen", "B04"), ("rb-leipzig", "RB Leipzig", "RBL"), ("eintracht", "Eintracht Frankfurt", "SGE"),
            ("stuttgart", "Stuttgart", "VFB"), ("wolfsburg", "Wolfsburg", "WOB"), ("monchengladbach", "Borussia Monchengladbach", "BMG")
        ])
        + teamList(.soccer, "Europe", "Ligue 1", icon: "⚽", [
            ("psg", "Paris Saint-Germain", "PSG"), ("marseille", "Marseille", "OM"), ("lyon", "Lyon", "OL"), ("monaco", "Monaco", "ASM"), ("lille", "Lille", "LOSC"), ("nice", "Nice", "NIC")
        ])
        + teamList(.soccer, "Europe", "Primeira Liga", icon: "⚽", [
            ("benfica", "Benfica", "BEN"), ("porto", "Porto", "POR"), ("sporting-cp", "Sporting CP", "SCP"), ("braga", "Braga", "BRA")
        ])
        + teamList(.soccer, "Europe", "Eredivisie", icon: "⚽", [
            ("ajax", "Ajax", "AJX"), ("psv", "PSV", "PSV"), ("feyenoord", "Feyenoord", "FEY"), ("az-alkmaar", "AZ Alkmaar", "AZ")
        ])
        + teamList(.soccer, "Europe", "Scottish Premiership", icon: "⚽", [
            ("celtic", "Celtic", "CEL"), ("rangers", "Rangers", "RAN"), ("hearts", "Hearts", "HEA"), ("aberdeen", "Aberdeen", "ABE")
        ])
        + teamList(.soccer, "Asia", "J1 League", icon: "⚽", [
            ("vissel-kobe", "Vissel Kobe", "KOB"), ("urawa-reds", "Urawa Reds", "URA"), ("kashima-antlers", "Kashima Antlers", "KAS"), ("yokohama-marinos", "Yokohama F. Marinos", "YFM")
        ])
        + teamList(.soccer, "Asia", "Saudi Pro League", icon: "⚽", [
            ("al-hilal", "Al Hilal", "HIL"), ("al-nassr", "Al Nassr", "NAS"), ("al-ittihad", "Al Ittihad", "ITT"), ("al-ahli", "Al Ahli", "AHL")
        ])
        + teamList(.soccer, "Asia", "K League", icon: "⚽", [
            ("ulsan", "Ulsan HD", "ULS"), ("jeonbuk", "Jeonbuk Hyundai", "JEO"), ("fc-seoul", "FC Seoul", "SEO"), ("pohang", "Pohang Steelers", "POH")
        ])

    private static let basketballCountries: [TeamPickerOption] = [
        country("usa", "United States Basketball", .basketball, "International", "International / national teams", code: "US", short: "USA"),
        country("canada", "Canada Basketball", .basketball, "International", "International / national teams", code: "CA"),
        country("france", "France Basketball", .basketball, "International", "International / national teams", code: "FR"),
        country("spain", "Spain Basketball", .basketball, "International", "International / national teams", code: "ES"),
        country("serbia", "Serbia Basketball", .basketball, "International", "International / national teams", code: "RS"),
        country("germany", "Germany Basketball", .basketball, "International", "International / national teams", code: "DE"),
        country("australia", "Australia Basketball", .basketball, "International", "International / national teams", code: "AU"),
        country("japan", "Japan Basketball", .basketball, "International", "International / national teams", code: "JP")
    ]

    private static let basketballTeams: [TeamPickerOption] =
        teamList(.basketball, "NBA", "Eastern Conference", icon: "🏀", [
            ("celtics", "Boston Celtics", "BOS"), ("nets", "Brooklyn Nets", "BKN"), ("knicks", "New York Knicks", "NYK"), ("76ers", "Philadelphia 76ers", "PHI"), ("raptors", "Toronto Raptors", "TOR"),
            ("bulls", "Chicago Bulls", "CHI"), ("cavaliers", "Cleveland Cavaliers", "CLE"), ("pistons", "Detroit Pistons", "DET"), ("pacers", "Indiana Pacers", "IND"), ("bucks", "Milwaukee Bucks", "MIL"),
            ("hawks", "Atlanta Hawks", "ATL"), ("hornets", "Charlotte Hornets", "CHA"), ("heat", "Miami Heat", "MIA"), ("magic", "Orlando Magic", "ORL"), ("wizards", "Washington Wizards", "WAS")
        ])
        + teamList(.basketball, "NBA", "Western Conference", icon: "🏀", [
            ("nuggets", "Denver Nuggets", "DEN"), ("timberwolves", "Minnesota Timberwolves", "MIN"), ("thunder", "Oklahoma City Thunder", "OKC"), ("trail-blazers", "Portland Trail Blazers", "POR"), ("jazz", "Utah Jazz", "UTA"),
            ("warriors", "Golden State Warriors", "GSW"), ("clippers", "LA Clippers", "LAC"), ("lakers", "Los Angeles Lakers", "LAL"), ("suns", "Phoenix Suns", "PHX"), ("kings", "Sacramento Kings", "SAC"),
            ("mavericks", "Dallas Mavericks", "DAL"), ("rockets", "Houston Rockets", "HOU"), ("grizzlies", "Memphis Grizzlies", "MEM"), ("pelicans", "New Orleans Pelicans", "NOP"), ("spurs", "San Antonio Spurs", "SAS")
        ])
        + teamList(.basketball, "WNBA", "WNBA", icon: "🏀", [
            ("dream", "Atlanta Dream", "ATL"), ("sky", "Chicago Sky", "CHI"), ("sun", "Connecticut Sun", "CON"), ("wings", "Dallas Wings", "DAL"), ("valkyries", "Golden State Valkyries", "GSV"),
            ("fever", "Indiana Fever", "IND"), ("aces", "Las Vegas Aces", "LVA"), ("sparks", "Los Angeles Sparks", "LAS"), ("lynx", "Minnesota Lynx", "MIN"), ("liberty", "New York Liberty", "NYL"),
            ("mercury", "Phoenix Mercury", "PHX"), ("storm", "Seattle Storm", "SEA"), ("mystics", "Washington Mystics", "WAS")
        ])
        + teamList(.basketball, "College Basketball", "SEC", icon: "🏀", [
            ("alabama", "Alabama", "ALA"), ("arkansas", "Arkansas", "ARK"), ("auburn", "Auburn", "AUB"), ("florida", "Florida", "FLA"), ("kentucky", "Kentucky", "UK"), ("lsu", "LSU", "LSU"), ("tennessee", "Tennessee", "TENN")
        ])
        + teamList(.basketball, "College Basketball", "Big Ten", icon: "🏀", [
            ("michigan", "Michigan", "MICH"), ("michigan-state", "Michigan State", "MSU"), ("ohio-state", "Ohio State", "OSU"), ("indiana", "Indiana", "IU"), ("purdue", "Purdue", "PUR"), ("ucla", "UCLA", "UCLA")
        ])
        + teamList(.basketball, "College Basketball", "ACC", icon: "🏀", [
            ("duke", "Duke", "DUKE"), ("unc", "North Carolina", "UNC"), ("nc-state", "NC State", "NCSU"), ("virginia", "Virginia", "UVA"), ("louisville", "Louisville", "LOU"), ("syracuse", "Syracuse", "SYR")
        ])
        + teamList(.basketball, "College Basketball", "Big 12", icon: "🏀", [
            ("kansas", "Kansas", "KU"), ("baylor", "Baylor", "BAY"), ("houston", "Houston", "HOU"), ("arizona", "Arizona", "ARIZ"), ("byu", "BYU", "BYU"), ("iowa-state", "Iowa State", "ISU")
        ])
        + teamList(.basketball, "College Basketball", "Big East", icon: "🏀", [
            ("uconn", "UConn", "CONN"), ("villanova", "Villanova", "NOVA"), ("marquette", "Marquette", "MARQ"), ("creighton", "Creighton", "CREI"), ("st-johns", "St. John's", "SJU"), ("georgetown", "Georgetown", "GTOWN")
        ])
        + teamList(.basketball, "College Basketball", "Pac-12", icon: "🏀", [
            ("oregon-state", "Oregon State", "OSU"), ("washington-state", "Washington State", "WSU")
        ])
        + teamList(.basketball, "College Basketball", "AAC", icon: "🏀", [
            ("memphis", "Memphis", "MEM"), ("wichita-state", "Wichita State", "WSU"), ("temple", "Temple", "TEM")
        ])

    private static let baseballCountries: [TeamPickerOption] = [
        country("usa", "United States Baseball", .baseball, "International", "International / national teams", code: "US", short: "USA"),
        country("japan", "Japan Baseball", .baseball, "International", "International / national teams", code: "JP"),
        country("mexico", "Mexico Baseball", .baseball, "International", "International / national teams", code: "MX"),
        country("canada", "Canada Baseball", .baseball, "International", "International / national teams", code: "CA"),
        country("korea", "South Korea Baseball", .baseball, "International", "International / national teams", code: "KR")
    ]

    private static let baseballTeams: [TeamPickerOption] =
        teamList(.baseball, "MLB", "American League East", icon: "⚾", [
            ("orioles", "Baltimore Orioles", "BAL"), ("red-sox", "Boston Red Sox", "BOS"), ("yankees", "New York Yankees", "NYY"), ("rays", "Tampa Bay Rays", "TB"), ("blue-jays", "Toronto Blue Jays", "TOR")
        ])
        + teamList(.baseball, "MLB", "American League Central", icon: "⚾", [
            ("white-sox", "Chicago White Sox", "CWS"), ("guardians", "Cleveland Guardians", "CLE"), ("tigers", "Detroit Tigers", "DET"), ("royals", "Kansas City Royals", "KC"), ("twins", "Minnesota Twins", "MIN")
        ])
        + teamList(.baseball, "MLB", "American League West", icon: "⚾", [
            ("astros", "Houston Astros", "HOU"), ("angels", "Los Angeles Angels", "LAA"), ("athletics", "Athletics", "ATH"), ("mariners", "Seattle Mariners", "SEA"), ("rangers", "Texas Rangers", "TEX")
        ])
        + teamList(.baseball, "MLB", "National League East", icon: "⚾", [
            ("braves", "Atlanta Braves", "ATL"), ("marlins", "Miami Marlins", "MIA"), ("mets", "New York Mets", "NYM"), ("phillies", "Philadelphia Phillies", "PHI"), ("nationals", "Washington Nationals", "WSH")
        ])
        + teamList(.baseball, "MLB", "National League Central", icon: "⚾", [
            ("cubs", "Chicago Cubs", "CHC"), ("reds", "Cincinnati Reds", "CIN"), ("brewers", "Milwaukee Brewers", "MIL"), ("pirates", "Pittsburgh Pirates", "PIT"), ("cardinals", "St. Louis Cardinals", "STL")
        ])
        + teamList(.baseball, "MLB", "National League West", icon: "⚾", [
            ("diamondbacks", "Arizona Diamondbacks", "ARI"), ("rockies", "Colorado Rockies", "COL"), ("dodgers", "Los Angeles Dodgers", "LAD"), ("padres", "San Diego Padres", "SD"), ("giants", "San Francisco Giants", "SF")
        ])

    private static let hockeyCountries: [TeamPickerOption] = [
        country("usa", "United States Hockey", .hockey, "International", "International / national teams", code: "US", short: "USA"),
        country("canada", "Canada Hockey", .hockey, "International", "International / national teams", code: "CA"),
        country("sweden", "Sweden Hockey", .hockey, "International", "International / national teams", code: "SE"),
        country("finland", "Finland Hockey", .hockey, "International", "International / national teams", code: "FI"),
        country("germany", "Germany Hockey", .hockey, "International", "International / national teams", code: "DE")
    ]

    private static let hockeyTeams: [TeamPickerOption] =
        teamList(.hockey, "NHL", "Eastern Conference", icon: "🏒", [
            ("bruins", "Boston Hockey", "BOS"), ("sabres", "Buffalo Hockey", "BUF"), ("red-wings", "Detroit Hockey", "DET"), ("panthers", "Florida Hockey", "FLA"), ("canadiens", "Montreal Hockey", "MTL"),
            ("senators", "Ottawa Hockey", "OTT"), ("lightning", "Tampa Hockey", "TBL"), ("maple-leafs", "Toronto Hockey", "TOR"), ("hurricanes", "Carolina Hockey", "CAR"), ("blue-jackets", "Columbus Hockey", "CBJ"),
            ("devils", "New Jersey Hockey", "NJD"), ("islanders", "New York Islanders", "NYI"), ("rangers", "New York Hockey", "NYR"), ("flyers", "Philadelphia Hockey", "PHI"), ("penguins", "Pittsburgh Hockey", "PIT"), ("capitals", "Washington Hockey", "WSH")
        ])
        + teamList(.hockey, "NHL", "Western Conference", icon: "🏒", [
            ("ducks", "Anaheim Hockey", "ANA"), ("flames", "Calgary Hockey", "CGY"), ("blackhawks", "Chicago Hockey", "CHI"), ("avalanche", "Colorado Hockey", "COL"), ("stars", "Dallas Hockey", "DAL"),
            ("oilers", "Edmonton Hockey", "EDM"), ("kings", "Los Angeles Hockey", "LAK"), ("wild", "Minnesota Hockey", "MIN"), ("predators", "Nashville Hockey", "NSH"), ("kraken", "Seattle Hockey", "SEA"),
            ("sharks", "San Jose Hockey", "SJS"), ("blues", "St. Louis Hockey", "STL"), ("utah", "Utah Hockey", "UTA"), ("canucks", "Vancouver Hockey", "VAN"), ("golden-knights", "Vegas Hockey", "VGK"), ("jets", "Winnipeg Hockey", "WPG")
        ])

    private static let footballTeams: [TeamPickerOption] =
        teamList(.football, "NFL", "AFC East", icon: "🏈", [
            ("bills", "Buffalo Bills", "BUF"), ("dolphins", "Miami Dolphins", "MIA"), ("patriots", "New England Patriots", "NE"), ("jets", "New York Jets", "NYJ")
        ])
        + teamList(.football, "NFL", "AFC North", icon: "🏈", [
            ("ravens", "Baltimore Ravens", "BAL"), ("bengals", "Cincinnati Bengals", "CIN"), ("browns", "Cleveland Browns", "CLE"), ("steelers", "Pittsburgh Steelers", "PIT")
        ])
        + teamList(.football, "NFL", "AFC South", icon: "🏈", [
            ("texans", "Houston Texans", "HOU"), ("colts", "Indianapolis Colts", "IND"), ("jaguars", "Jacksonville Jaguars", "JAX"), ("titans", "Tennessee Titans", "TEN")
        ])
        + teamList(.football, "NFL", "AFC West", icon: "🏈", [
            ("broncos", "Denver Broncos", "DEN"), ("chiefs", "Kansas City Chiefs", "KC"), ("raiders", "Las Vegas Raiders", "LV"), ("chargers", "Los Angeles Chargers", "LAC")
        ])
        + teamList(.football, "NFL", "NFC East", icon: "🏈", [
            ("cowboys", "Dallas Cowboys", "DAL"), ("giants", "New York Giants", "NYG"), ("eagles", "Philadelphia Eagles", "PHI"), ("commanders", "Washington Commanders", "WAS")
        ])
        + teamList(.football, "NFL", "NFC North", icon: "🏈", [
            ("bears", "Chicago Bears", "CHI"), ("lions", "Detroit Lions", "DET"), ("packers", "Green Bay Packers", "GB"), ("vikings", "Minnesota Vikings", "MIN")
        ])
        + teamList(.football, "NFL", "NFC South", icon: "🏈", [
            ("falcons", "Atlanta Falcons", "ATL"), ("panthers", "Carolina Panthers", "CAR"), ("saints", "New Orleans Saints", "NO"), ("buccaneers", "Tampa Bay Buccaneers", "TB")
        ])
        + teamList(.football, "NFL", "NFC West", icon: "🏈", [
            ("cardinals", "Arizona Cardinals", "ARI"), ("rams", "Los Angeles Rams", "LAR"), ("49ers", "San Francisco 49ers", "SF"), ("seahawks", "Seattle Seahawks", "SEA")
        ])
        + teamList(.football, "College Football", "SEC", icon: "🏈", [
            ("alabama", "Alabama", "ALA"), ("georgia", "Georgia", "UGA"), ("lsu", "LSU", "LSU"), ("florida", "Florida", "FLA"), ("tennessee", "Tennessee", "TENN"), ("texas", "Texas", "TEX"), ("oklahoma", "Oklahoma", "OU"), ("ole-miss", "Ole Miss", "MISS")
        ])
        + teamList(.football, "College Football", "Big Ten", icon: "🏈", [
            ("ohio-state", "Ohio State", "OSU"), ("michigan", "Michigan", "MICH"), ("penn-state", "Penn State", "PSU"), ("oregon", "Oregon", "ORE"), ("usc", "USC", "USC"), ("ucla", "UCLA", "UCLA"), ("wisconsin", "Wisconsin", "WIS"), ("iowa", "Iowa", "IOWA")
        ])
        + teamList(.football, "College Football", "ACC", icon: "🏈", [
            ("clemson", "Clemson", "CLEM"), ("florida-state", "Florida State", "FSU"), ("miami", "Miami", "MIA"), ("unc", "North Carolina", "UNC"), ("nc-state", "NC State", "NCSU"), ("virginia-tech", "Virginia Tech", "VT")
        ])
        + teamList(.football, "College Football", "Big 12", icon: "🏈", [
            ("byu", "BYU", "BYU"), ("utah", "Utah", "UTAH"), ("kansas-state", "Kansas State", "KSU"), ("oklahoma-state", "Oklahoma State", "OKST"), ("colorado", "Colorado", "CU"), ("tcu", "TCU", "TCU"), ("baylor", "Baylor", "BAY"), ("texas-tech", "Texas Tech", "TTU")
        ])
        + teamList(.football, "College Football", "Pac-12", icon: "🏈", [
            ("oregon-state", "Oregon State", "OSU"), ("washington-state", "Washington State", "WSU")
        ])
        + teamList(.football, "College Football", "AAC", icon: "🏈", [
            ("memphis", "Memphis", "MEM"), ("tulane", "Tulane", "TUL"), ("navy", "Navy", "NAVY"), ("usf", "South Florida", "USF"), ("utsa", "UTSA", "UTSA")
        ])

    private static func flagEmoji(forRegionCode regionCode: String) -> String {
        regionCode
            .uppercased()
            .unicodeScalars
            .compactMap { UnicodeScalar(127397 + $0.value) }
            .map(String.init)
            .joined()
    }
}

private extension String {
    var pickerID: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
            .lowercased()
    }
}
