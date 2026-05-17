import CoreLocation
import Foundation
#if canImport(WeatherKit)
import WeatherKit
#endif

struct DiscoverWeather: Equatable {
    let temperature: Int
    let symbolName: String
}

/// Lightweight cached weather for the Discover map pill (WeatherKit → Open-Meteo fallback).
@MainActor
final class DiscoverWeatherService {
    static let shared = DiscoverWeatherService()

    private struct CacheEntry {
        let coordinate: CLLocationCoordinate2D
        let weather: DiscoverWeather
        let fetchedAt: Date
        let sourceLabel: String
        let locationLabel: String
    }

    private var cache: CacheEntry?
    private var inFlightCoordinate: CLLocationCoordinate2D?
    private var inFlightTask: Task<DiscoverWeather?, Never>?

    /// 20 minutes — within the requested 15–30 minute window.
    private let cacheTTL: TimeInterval = 20 * 60
    /// ~5 mi — ignore small pans/zooms.
    private let significantMoveMeters: CLLocationDistance = 8_000

    private init() {}

    func weather(
        for coordinate: CLLocationCoordinate2D,
        force: Bool = false,
        requestedBasis: String = "unknown"
    ) async -> DiscoverWeather? {
        let rounded = Self.roundedCoordinate(coordinate)

        if !force, let cached = cache, !shouldRefresh(for: rounded, entry: cached) {
            logDebug(
                requestedBasis: requestedBasis,
                source: cached.sourceLabel,
                location: cached.locationLabel,
                temp: cached.weather.temperature,
                cacheHit: true,
                finalBasis: requestedBasis
            )
            return cached.weather
        }

        if let inFlightCoordinate,
           let inFlightTask,
           coordinatesAreClose(inFlightCoordinate, rounded, thresholdMeters: 400) {
            return await inFlightTask.value
        }

        let task = Task { @MainActor () -> DiscoverWeather? in
            await fetchAndCache(for: rounded, requestedBasis: requestedBasis)
        }
        inFlightCoordinate = rounded
        inFlightTask = task
        let result = await task.value
        inFlightTask = nil
        inFlightCoordinate = nil
        return result
    }

    private func fetchAndCache(for coordinate: CLLocationCoordinate2D, requestedBasis: String) async -> DiscoverWeather? {
        let locationLabel = Self.coordinateLabel(coordinate)

        if let kit = await fetchWeatherKit(coordinate: coordinate) {
            storeCache(coordinate: coordinate, weather: kit, source: "weatherkit", location: locationLabel)
            logDebug(
                requestedBasis: requestedBasis,
                source: "weatherkit",
                location: locationLabel,
                temp: kit.temperature,
                cacheHit: false,
                finalBasis: requestedBasis
            )
            return kit
        }

        if let meteo = await fetchOpenMeteo(coordinate: coordinate) {
            storeCache(coordinate: coordinate, weather: meteo, source: "open-meteo", location: locationLabel)
            logDebug(
                requestedBasis: requestedBasis,
                source: "open-meteo",
                location: locationLabel,
                temp: meteo.temperature,
                cacheHit: false,
                finalBasis: requestedBasis
            )
            return meteo
        }

        logDebug(
            requestedBasis: requestedBasis,
            source: "unavailable",
            location: locationLabel,
            temp: nil,
            cacheHit: false,
            finalBasis: requestedBasis
        )
        return cache?.weather
    }

    private func shouldRefresh(for coordinate: CLLocationCoordinate2D, entry: CacheEntry) -> Bool {
        if Date().timeIntervalSince(entry.fetchedAt) > cacheTTL {
            return true
        }
        let previous = CLLocation(latitude: entry.coordinate.latitude, longitude: entry.coordinate.longitude)
        let next = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return previous.distance(from: next) > significantMoveMeters
    }

    private func storeCache(
        coordinate: CLLocationCoordinate2D,
        weather: DiscoverWeather,
        source: String,
        location: String
    ) {
        cache = CacheEntry(
            coordinate: coordinate,
            weather: weather,
            fetchedAt: Date(),
            sourceLabel: source,
            locationLabel: location
        )
    }

    #if canImport(WeatherKit)
    private func fetchWeatherKit(coordinate: CLLocationCoordinate2D) async -> DiscoverWeather? {
        do {
            let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            let weather = try await WeatherService.shared.weather(for: location)
            let current = weather.currentWeather
            let fahrenheit = Int(current.temperature.converted(to: .fahrenheit).value.rounded())
            let symbol = current.symbolName.isEmpty ? "cloud.sun.fill" : current.symbolName
            return DiscoverWeather(temperature: fahrenheit, symbolName: symbol)
        } catch {
#if DEBUG
            print("[DiscoverWeatherDebug] weatherkitError=\(error.localizedDescription)")
#endif
            return nil
        }
    }
    #else
    private func fetchWeatherKit(coordinate: CLLocationCoordinate2D) async -> DiscoverWeather? {
        nil
    }
    #endif

    private func fetchOpenMeteo(coordinate: CLLocationCoordinate2D) async -> DiscoverWeather? {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", coordinate.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code"),
            URLQueryItem(name: "temperature_unit", value: "fahrenheit"),
            URLQueryItem(name: "timezone", value: "auto")
        ]
        guard let url = components?.url else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
                return nil
            }
            let decoded = try JSONDecoder().decode(OpenMeteoCurrentResponse.self, from: data)
            let temp = Int(decoded.current.temperature2m.rounded())
            let symbol = Self.symbolName(forWMOCode: decoded.current.weatherCode)
            return DiscoverWeather(temperature: temp, symbolName: symbol)
        } catch {
#if DEBUG
            print("[DiscoverWeatherDebug] openMeteoError=\(error.localizedDescription)")
#endif
            return nil
        }
    }

    private static func symbolName(forWMOCode code: Int) -> String {
        switch code {
        case 0:
            return "sun.max.fill"
        case 1, 2, 3:
            return "cloud.sun.fill"
        case 45, 48:
            return "cloud.fog.fill"
        case 51, 53, 55, 56, 57:
            return "cloud.drizzle.fill"
        case 61, 63, 65, 66, 67, 80, 81, 82:
            return "cloud.rain.fill"
        case 71, 73, 75, 77, 85, 86:
            return "cloud.snow.fill"
        case 95, 96, 99:
            return "cloud.bolt.rain.fill"
        default:
            return "cloud.fill"
        }
    }

    private static func roundedCoordinate(_ coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: (coordinate.latitude * 100).rounded() / 100,
            longitude: (coordinate.longitude * 100).rounded() / 100
        )
    }

    private func coordinatesAreClose(
        _ lhs: CLLocationCoordinate2D,
        _ rhs: CLLocationCoordinate2D,
        thresholdMeters: CLLocationDistance
    ) -> Bool {
        let a = CLLocation(latitude: lhs.latitude, longitude: lhs.longitude)
        let b = CLLocation(latitude: rhs.latitude, longitude: rhs.longitude)
        return a.distance(from: b) <= thresholdMeters
    }

    private static func coordinateLabel(_ coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.2f,%.2f", coordinate.latitude, coordinate.longitude)
    }

    private func logDebug(
        requestedBasis: String,
        source: String,
        location: String,
        temp: Int?,
        cacheHit: Bool,
        finalBasis: String
    ) {
#if DEBUG
        print("[DiscoverWeatherDebug] requestedBasis=\(requestedBasis)")
        print("[DiscoverWeatherDebug] finalBasis=\(finalBasis)")
        print("[DiscoverWeatherDebug] source=\(source)")
        print("[DiscoverWeatherDebug] location=\(location)")
        print("[DiscoverWeatherDebug] temp=\(temp.map(String.init) ?? "nil")")
        print("[DiscoverWeatherDebug] cacheHit=\(cacheHit)")
#endif
    }
}

private struct OpenMeteoCurrentResponse: Decodable {
    struct Current: Decodable {
        let temperature2m: Double
        let weatherCode: Int

        enum CodingKeys: String, CodingKey {
            case temperature2m = "temperature_2m"
            case weatherCode = "weather_code"
        }
    }

    let current: Current
}
