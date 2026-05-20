import SwiftUI

/// Stored country codes on `venue_claims` / owner forms.
enum BusinessLocationCountryPolicy {
    static let defaultCountryCode = "USA"

    static let supportedCountryChoices: [(code: String, label: String)] = [
        (code: "USA", label: "United States"),
        (code: "CAN", label: "Canada"),
        (code: "MEX", label: "Mexico"),
        (code: "FRA", label: "France"),
        (code: "DEU", label: "Germany"),
        (code: "ITA", label: "Italy"),
        (code: "ESP", label: "Spain"),
        (code: "PRT", label: "Portugal"),
        (code: "JPN", label: "Japan"),
        (code: "CHN", label: "China"),
        (code: "BRA", label: "Brazil"),
        (code: "GBR", label: "United Kingdom"),
        (code: "AUS", label: "Australia"),
        (code: "OTHER", label: "Other country"),
    ]

    static var supportedCountryCodes: Set<String> {
        Set(supportedCountryChoices.map(\.code))
    }

    /// When more than one country is supported, the form shows an editable `Picker`; otherwise the value stays fixed at default.
    static var showsCountryPicker: Bool { supportedCountryChoices.count > 1 }

    static func normalizedStoredCountryCode(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if t.isEmpty { return "" }
        if supportedCountryCodes.contains(t) { return t }
        return t
    }

    static func countryName(for code: String) -> String {
        let normalized = normalizedStoredCountryCode(code)
        return supportedCountryChoices.first(where: { $0.code == normalized })?.label ?? normalized
    }

    static func labels(for code: String) -> BusinessLocationAddressLabels {
        switch normalizedStoredCountryCode(code) {
        case "USA":
            return BusinessLocationAddressLabels(locality: "City", region: "State", postalCode: "ZIP", regionRequired: true, localityRequired: true)
        case "CAN":
            return BusinessLocationAddressLabels(locality: "City", region: "Province", postalCode: "Postal Code", regionRequired: false, localityRequired: true)
        case "MEX":
            return BusinessLocationAddressLabels(locality: "City / Locality", region: "State", postalCode: "Codigo Postal", regionRequired: false, localityRequired: true)
        case "FRA", "DEU", "ITA", "ESP", "PRT":
            return BusinessLocationAddressLabels(locality: "City / Locality", region: "Region / Province (optional)", postalCode: "Postal Code", regionRequired: false, localityRequired: true)
        case "JPN":
            return BusinessLocationAddressLabels(locality: "City / Ward", region: "Prefecture", postalCode: "Postal Code", regionRequired: false, localityRequired: false)
        case "CHN":
            return BusinessLocationAddressLabels(locality: "City / District", region: "Province", postalCode: "Postal Code", regionRequired: false, localityRequired: false)
        case "BRA":
            return BusinessLocationAddressLabels(locality: "City / Locality", region: "State", postalCode: "CEP", regionRequired: false, localityRequired: true)
        default:
            return BusinessLocationAddressLabels(locality: "City / Locality", region: "Region", postalCode: "Postal code", regionRequired: false, localityRequired: false)
        }
    }

    static func clearDefaultRegionIfNeeded(_ region: inout String, whenCountryChangesTo country: String) {
        let normalized = normalizedStoredCountryCode(country)
        guard normalized != "USA" else { return }
        if region.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "UT" {
            region = ""
        }
    }
}

struct BusinessLocationAddressLabels {
    let locality: String
    let region: String
    let postalCode: String
    let regionRequired: Bool
    let localityRequired: Bool
}

enum BusinessVenueAddressFormatter {
    static func formattedAddress(
        line1: String,
        line2: String = "",
        locality: String,
        region: String,
        postalCode: String,
        countryCode: String
    ) -> String {
        let country = BusinessLocationCountryPolicy.countryName(for: countryCode)
        let countryCode = BusinessLocationCountryPolicy.normalizedStoredCountryCode(countryCode)
        let l1 = trimmed(line1)
        let l2 = trimmed(line2)
        let city = trimmed(locality)
        let reg = trimmed(region)
        let postal = trimmed(postalCode)

        switch countryCode {
        case "JPN", "CHN":
            return joined([country, postal, reg, city, l1, l2], separator: ", ")
        case "FRA", "DEU", "ITA", "ESP", "PRT":
            let cityLine = joined([postal, city], separator: " ")
            return joined([l1, l2, cityLine, reg, country], separator: ", ")
        case "BRA":
            let cityRegion = joined([city, reg], separator: " - ")
            return joined([l1, l2, cityRegion, postal.isEmpty ? "" : "CEP \(postal)", country], separator: ", ")
        default:
            let regionPostal = joined([reg, postal], separator: " ")
            return joined([l1, l2, city, regionPostal, country], separator: ", ")
        }
    }

    static func geocodeQuery(
        line1: String,
        line2: String = "",
        locality: String,
        region: String,
        postalCode: String,
        countryCode: String
    ) -> String {
        formattedAddress(
            line1: line1,
            line2: line2,
            locality: locality,
            region: region,
            postalCode: postalCode,
            countryCode: countryCode
        )
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func joined(_ values: [String], separator: String) -> String {
        values.filter { !$0.isEmpty }.joined(separator: separator)
    }
}

/// US states + DC for business location forms; tuple `.0` is the stored 2-letter abbreviation.
enum USStatesForBusinessLocation {
    static let abbreviationsSortedByName: [(String, String)] = [
        ("AL", "Alabama"),
        ("AK", "Alaska"),
        ("AZ", "Arizona"),
        ("AR", "Arkansas"),
        ("CA", "California"),
        ("CO", "Colorado"),
        ("CT", "Connecticut"),
        ("DE", "Delaware"),
        ("DC", "District of Columbia"),
        ("FL", "Florida"),
        ("GA", "Georgia"),
        ("HI", "Hawaii"),
        ("ID", "Idaho"),
        ("IL", "Illinois"),
        ("IN", "Indiana"),
        ("IA", "Iowa"),
        ("KS", "Kansas"),
        ("KY", "Kentucky"),
        ("LA", "Louisiana"),
        ("ME", "Maine"),
        ("MD", "Maryland"),
        ("MA", "Massachusetts"),
        ("MI", "Michigan"),
        ("MN", "Minnesota"),
        ("MS", "Mississippi"),
        ("MO", "Missouri"),
        ("MT", "Montana"),
        ("NE", "Nebraska"),
        ("NV", "Nevada"),
        ("NH", "New Hampshire"),
        ("NJ", "New Jersey"),
        ("NM", "New Mexico"),
        ("NY", "New York"),
        ("NC", "North Carolina"),
        ("ND", "North Dakota"),
        ("OH", "Ohio"),
        ("OK", "Oklahoma"),
        ("OR", "Oregon"),
        ("PA", "Pennsylvania"),
        ("RI", "Rhode Island"),
        ("SC", "South Carolina"),
        ("SD", "South Dakota"),
        ("TN", "Tennessee"),
        ("TX", "Texas"),
        ("UT", "Utah"),
        ("VT", "Vermont"),
        ("VA", "Virginia"),
        ("WA", "Washington"),
        ("WV", "West Virginia"),
        ("WI", "Wisconsin"),
        ("WY", "Wyoming"),
    ]
    .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }

    static let validCodes: Set<String> = Set(abbreviationsSortedByName.map(\.0))
}

struct BusinessLocationCountryField: View {
    @Binding var countryCode: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if BusinessLocationCountryPolicy.showsCountryPicker {
            Picker("Country", selection: $countryCode) {
                ForEach(BusinessLocationCountryPolicy.supportedCountryChoices, id: \.code) { opt in
                    Text(opt.label).tag(opt.code)
                }
            }
            .pickerStyle(.menu)
            .font(FGTypography.body)
            .tint(FGColor.accentBlue)
        } else {
            LabeledContent("Country") {
                Text(readOnlyCountryLine)
                    .font(FGTypography.body)
                    .foregroundStyle(FGColor.primaryText(colorScheme))
            }
            .foregroundStyle(FGColor.secondaryText(colorScheme))
        }
    }

    private var readOnlyCountryLine: String {
        let code = countryCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if let match = BusinessLocationCountryPolicy.supportedCountryChoices.first(where: { $0.code == code }) {
            return "\(match.label) (\(match.code))"
        }
        if let only = BusinessLocationCountryPolicy.supportedCountryChoices.first {
            return "\(only.label) (\(only.code))"
        }
        return BusinessLocationCountryPolicy.defaultCountryCode
    }
}

struct BusinessLocationRegionField: View {
    let countryCode: String
    let labels: BusinessLocationAddressLabels
    @Binding var region: String

    var body: some View {
        if BusinessLocationCountryPolicy.normalizedStoredCountryCode(countryCode) == "USA" {
            BusinessLocationUSStatePicker(title: labels.region, stateCode: $region)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            TextField(labels.region, text: $region)
                .textInputAutocapitalization(.words)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct BusinessLocationUSStatePicker: View {
    var title: String = "State"
    @Binding var stateCode: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Picker(title, selection: $stateCode) {
            ForEach(USStatesForBusinessLocation.abbreviationsSortedByName, id: \.0) { row in
                Text("\(row.0) — \(row.1)").tag(row.0)
            }
        }
        .font(FGTypography.body)
        .tint(FGColor.accentBlue)
        .foregroundStyle(FGColor.primaryText(colorScheme))
    }
}
