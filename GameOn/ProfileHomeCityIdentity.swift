import Foundation
import MapKit

enum ProfileHomeCityIdentity {
    static func displayLine(city: String?, region: String?, country: String?) -> String? {
        let trimmedCity = trimmed(city)
        guard !trimmedCity.isEmpty else { return nil }
        let trimmedRegion = trimmed(region)
        let trimmedCountry = trimmed(country)
        if !trimmedRegion.isEmpty {
            return "\(trimmedCity), \(trimmedRegion)"
        }
        if !trimmedCountry.isEmpty {
            return "\(trimmedCity), \(trimmedCountry)"
        }
        return trimmedCity
    }

    static func parse(mapItem: MKMapItem) -> (city: String, region: String, country: String, display: String) {
        let city: String
        let region: String
        let country: String

        if #available(iOS 26.0, *) {
            let parsed = parseModern(mapItem: mapItem)
            city = parsed.city
            region = parsed.region
            country = parsed.country
        } else {
            city = trimmed(mapItem.placemark.locality).ifEmpty(fallback: trimmed(mapItem.name))
            region = trimmed(mapItem.placemark.administrativeArea)
            country = trimmed(mapItem.placemark.country)
        }

        let display = displayLine(city: city, region: region, country: country) ?? city
        return (city: city, region: region, country: country, display: display)
    }

    @available(iOS 26.0, *)
    private static func parseModern(mapItem: MKMapItem) -> (city: String, region: String, country: String) {
        let representations = mapItem.addressRepresentations
        let city = trimmed(representations?.cityName).ifEmpty(fallback: trimmed(mapItem.name))
        let cityContext = trimmed(representations?.cityWithContext)
        let lines = addressLines(from: mapItem, includingRegion: false)
        let region = trimmed(
            administrativeArea(from: cityContext, city: city)
                ?? administrativeArea(from: lines, city: city)
        )
        let country = trimmed(
            countryName(from: cityContext, city: city)
                ?? countryName(from: addressLines(from: mapItem, includingRegion: true), city: city)
        )
        return (city: city, region: region, country: country)
    }

    @available(iOS 26.0, *)
    private static func addressLines(from mapItem: MKMapItem, includingRegion: Bool) -> [String] {
        let representations = mapItem.addressRepresentations
        let addressText = representations?.fullAddress(includingRegion: includingRegion, singleLine: false)
            ?? mapItem.address?.fullAddress
            ?? mapItem.address?.shortAddress
        return addressText?
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
    }

    @available(iOS 26.0, *)
    private static func administrativeArea(from cityContext: String, city: String) -> String? {
        guard
            !cityContext.isEmpty,
            !city.isEmpty,
            cityContext.localizedCaseInsensitiveContains(city),
            let commaIndex = cityContext.firstIndex(of: ",")
        else {
            return nil
        }

        let remainder = cityContext[cityContext.index(after: commaIndex)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let part = remainder.split(separator: ",").first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return part.isEmpty ? nil : part
    }

    @available(iOS 26.0, *)
    private static func administrativeArea(from lines: [String], city: String?) -> String? {
        guard
            let city,
            !city.isEmpty,
            let cityLine = lines.first(where: { $0.localizedCaseInsensitiveContains(city) }),
            let commaIndex = cityLine.firstIndex(of: ",")
        else {
            return nil
        }

        let remainder = cityLine[cityLine.index(after: commaIndex)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let part = remainder.split(separator: ",").first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return part.isEmpty ? nil : part
    }

    @available(iOS 26.0, *)
    private static func countryName(from cityContext: String, city: String) -> String? {
        guard
            !cityContext.isEmpty,
            !city.isEmpty,
            cityContext.localizedCaseInsensitiveContains(city),
            let commaIndex = cityContext.firstIndex(of: ",")
        else {
            return nil
        }

        let remainder = cityContext[cityContext.index(after: commaIndex)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = remainder.split(separator: ",").map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard parts.count >= 2 else { return nil }
        return parts[1].isEmpty ? nil : parts[1]
    }

    @available(iOS 26.0, *)
    private static func countryName(from lines: [String], city: String?) -> String? {
        guard lines.count >= 2, let last = lines.last else { return nil }
        if let city, last.localizedCaseInsensitiveContains(city) { return nil }
        let value = trimmed(last)
        return value.isEmpty ? nil : value
    }

    private static func trimmed(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

private extension String {
    func ifEmpty(fallback: String) -> String {
        isEmpty ? fallback : self
    }
}
