import SwiftUI

/// Stored country codes on `venue_claims` / owner forms. Expand `supportedCountryChoices` to enable a country `Picker`.
enum BusinessLocationCountryPolicy {
    static let defaultCountryCode = "USA"

    static let supportedCountryChoices: [(code: String, label: String)] = [
        (code: "USA", label: "United States"),
    ]

    static var supportedCountryCodes: Set<String> {
        Set(supportedCountryChoices.map(\.code))
    }

    /// When more than one country is supported, the form shows an editable `Picker`; otherwise the value stays fixed at default.
    static var showsCountryPicker: Bool { supportedCountryChoices.count > 1 }

    static func normalizedStoredCountryCode(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if supportedCountryCodes.contains(t) { return t }
        return defaultCountryCode
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

    var body: some View {
        if BusinessLocationCountryPolicy.showsCountryPicker {
            Picker("Country", selection: $countryCode) {
                ForEach(BusinessLocationCountryPolicy.supportedCountryChoices, id: \.code) { opt in
                    Text(opt.label).tag(opt.code)
                }
            }
        } else {
            LabeledContent("Country") {
                Text(readOnlyCountryLine)
                    .foregroundStyle(.primary)
            }
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

struct BusinessLocationUSStatePicker: View {
    var title: String = "State"
    @Binding var stateCode: String

    var body: some View {
        Picker(title, selection: $stateCode) {
            ForEach(USStatesForBusinessLocation.abbreviationsSortedByName, id: \.0) { row in
                Text("\(row.0) — \(row.1)").tag(row.0)
            }
        }
    }
}
