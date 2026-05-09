import Foundation

struct SportsDBResponse: Decodable {
    let events: [SportsDBEvent]?
}

struct SportsDBEvent: Decodable {
    let idEvent: String?
    let strEvent: String?
    let strSport: String?
    let strLeague: String?
    let dateEvent: String?
    let strTime: String?
    let strCountry: String?
}

final class SportsAPIService {
    
    static let shared = SportsAPIService()
    
    private init() {}
    
    func fetchEvents(for date: Date, sport: String) async throws -> [SportsEvent] {
        var allEvents: [SportsEvent] = []
        
        for source in SportsDataSources.sources where source.isEnabled {
            switch source.provider {
            case .theSportsDB:
                let events = try await fetchFromTheSportsDB(
                    date: date,
                    sport: sport,
                    apiKey: source.apiKey
                )
                allEvents.append(contentsOf: events)

            case .apiSports:
                // Disabled for now. We will connect this later when you add an API key.
                continue

            case .sportsDataIO:
                // Disabled for now. We will connect this later when you add an API key.
                continue

            case .sportradar:
                // Disabled for now. We will connect this later when you add an API key.
                continue
            }
        }
        
        return deduplicateEvents(allEvents)
    }
    
    private func fetchFromTheSportsDB(date: Date, sport: String, apiKey: String) async throws -> [SportsEvent] {
        let dateString = Self.apiDateFormatter.string(from: date)
        
        var urlString = "https://www.thesportsdb.com/api/v1/json/\(apiKey)/eventsday.php?d=\(dateString)"
        
        if sport != "All" {
            let apiSport = mapSportForTheSportsDB(sport)
            let encodedSport = apiSport.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? apiSport
            urlString += "&s=\(encodedSport)"
        }
        
        print("Fetching events:", urlString)
        
        guard let url = URL(string: urlString) else {
            return []
        }
        
        let (data, _) = try await URLSession.shared.data(from: url)
        let decoded = try JSONDecoder().decode(SportsDBResponse.self, from: data)
        
        return (decoded.events ?? []).compactMap { apiEvent in
            guard let title = apiEvent.strEvent, !title.isEmpty else {
                return nil
            }
            
            return SportsEvent(
                title: title,
                sport: normalizeSport(apiEvent.strSport ?? sport),
                league: apiEvent.strLeague ?? "Unknown League",
                date: date,
                time: Self.cleanTime(apiEvent.strTime),
                country: apiEvent.strCountry ?? "Unknown"
            )
        }
    }
    
    private func deduplicateEvents(_ events: [SportsEvent]) -> [SportsEvent] {
        var seenKeys = Set<String>()
        var uniqueEvents: [SportsEvent] = []
        
        for event in events {
            let key = duplicateKey(for: event)
            
            if !seenKeys.contains(key) {
                seenKeys.insert(key)
                uniqueEvents.append(event)
            }
        }
        
        return uniqueEvents.sorted {
            $0.time < $1.time
        }
    }
    
    private func duplicateKey(for event: SportsEvent) -> String {
        let normalizedTitle = event.title
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "vs", with: "")
            .replacingOccurrences(of: ".", with: "")
        
        let dateString = Self.apiDateFormatter.string(from: event.date)
        let normalizedSport = event.sport.lowercased()
        
        return "\(normalizedTitle)-\(normalizedSport)-\(dateString)"
    }
    
    private func mapSportForTheSportsDB(_ sport: String) -> String {
        switch sport {
        case "NBA":
            return "Basketball"
        case "NFL":
            return "American Football"
        case "UFC":
            return "Fighting"
        default:
            return sport
        }
    }
    
    private func normalizeSport(_ sport: String) -> String {
        switch sport {
        case "Basketball":
            return "NBA"
        case "American Football":
            return "NFL"
        case "Fighting":
            return "UFC"
        default:
            return sport
        }
    }
    
    private static let apiDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    
    private static func cleanTime(_ rawTime: String?) -> String {
        guard let rawTime, !rawTime.isEmpty else {
            return "Time TBD"
        }
        
        let parts = rawTime.split(separator: "+")
        return String(parts.first ?? "Time TBD")
    }
}
