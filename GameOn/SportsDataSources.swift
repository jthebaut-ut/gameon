import Foundation

enum SportsDataProvider: String, CaseIterable {
    case theSportsDB
    case apiSports
    case sportsDataIO
    case sportradar
}

struct SportsDataSourceConfig {
    let provider: SportsDataProvider
    let isEnabled: Bool
    let apiKey: String
    let baseURL: String
}

struct SportsDataSources {

    static let sources: [SportsDataSourceConfig] = [

        // MARK: - TheSportsDB

        SportsDataSourceConfig(
            provider: .theSportsDB,
            isEnabled: true,
            apiKey: "123",
            baseURL: "https://www.thesportsdb.com/api/v1/json"
        ),

        // MARK: - API-SPORTS

        SportsDataSourceConfig(
            provider: .apiSports,
            isEnabled: false,
            apiKey: "YOUR_API_SPORTS_KEY",
            baseURL: "https://v3.football.api-sports.io"
        ),

        // MARK: - SportsDataIO

        SportsDataSourceConfig(
            provider: .sportsDataIO,
            isEnabled: false,
            apiKey: "YOUR_SPORTSDATAIO_KEY",
            baseURL: "https://api.sportsdata.io/v3"
        ),

        // MARK: - Sportradar

        SportsDataSourceConfig(
            provider: .sportradar,
            isEnabled: false,
            apiKey: "YOUR_SPORTRADAR_KEY",
            baseURL: "https://api.sportradar.com"
        )
    ]
}
