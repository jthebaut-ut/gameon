import Foundation
import CoreLocation
import MapKit
import SwiftUI

struct BusinessVenueLocationDraft: Equatable, Sendable {
    var addressLine1: String
    var addressLine2: String
    var locality: String
    var region: String
    var postalCode: String
    var countryCode: String
    var latitude: Double?
    var longitude: Double?
    var formattedAddress: String?

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        return CLLocationCoordinate2DIsValid(coordinate) ? coordinate : nil
    }

    var displayAddress: String {
        let formatted = formattedAddress?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !formatted.isEmpty { return formatted }
        return BusinessVenueAddressFormatter.formattedAddress(
            line1: addressLine1,
            line2: addressLine2,
            locality: locality,
            region: region,
            postalCode: postalCode,
            countryCode: countryCode
        )
    }
}

struct BusinessVenueLocationPinPreview: View {
    let draft: BusinessVenueLocationDraft
    let isLocked: Bool
    let onAdjust: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(draft.coordinate == nil ? "Pin on Map" : "Venue pin", systemImage: "mappin.and.ellipse")
                    .font(FGTypography.cardTitle.weight(.semibold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                Spacer(minLength: 8)
                Button(draft.coordinate == nil ? "Pin on Map" : "Adjust Pin") {
                    onAdjust()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isLocked)
            }

            if let coordinate = draft.coordinate {
                Map(initialPosition: .region(previewRegion(for: coordinate))) {
                    Annotation("Venue", coordinate: coordinate) {
                        Image(systemName: "building.2.crop.circle.fill")
                            .font(.system(size: 32))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(FGColor.businessGreen, Color.white)
                            .shadow(color: .black.opacity(0.24), radius: 4, y: 2)
                    }
                    .annotationTitles(.hidden)
                }
                .allowsHitTesting(false)
                .frame(height: 142)
                .clipShape(RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                        .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
                }

                Text(draft.displayAddress)
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .lineLimit(3)
            } else {
                Text("Drop a precise pin so fans can find this venue globally, even when the typed address is ambiguous.")
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
            }
        }
        .padding(FGSpacing.md)
        .background(FGAdaptiveSurface.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
        }
    }

    private func previewRegion(for coordinate: CLLocationCoordinate2D) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.018, longitudeDelta: 0.018)
        )
    }
}

struct BusinessVenueLocationPinPickerView: View {
    @ObservedObject var viewModel: MapViewModel
    let initialDraft: BusinessVenueLocationDraft
    let fallbackCoordinate: CLLocationCoordinate2D
    let onCancel: () -> Void
    let onConfirm: (BusinessVenueLocationDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var draft: BusinessVenueLocationDraft
    @State private var pinCoordinate: CLLocationCoordinate2D
    @State private var cameraPosition: MapCameraPosition
    @State private var searchText: String
    @State private var statusText = "Tap the map, search an address, or use current location."
    @State private var isResolving = false
    @State private var resolveTask: Task<Void, Never>?

    init(
        viewModel: MapViewModel,
        initialDraft: BusinessVenueLocationDraft,
        fallbackCoordinate: CLLocationCoordinate2D,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping (BusinessVenueLocationDraft) -> Void
    ) {
        self.viewModel = viewModel
        self.initialDraft = initialDraft
        self.fallbackCoordinate = fallbackCoordinate
        self.onCancel = onCancel
        self.onConfirm = onConfirm

        let start = initialDraft.coordinate ?? fallbackCoordinate
        _draft = State(initialValue: initialDraft)
        _pinCoordinate = State(initialValue: start)
        _cameraPosition = State(
            initialValue: .region(
                MKCoordinateRegion(
                    center: start,
                    span: MKCoordinateSpan(latitudeDelta: 0.035, longitudeDelta: 0.035)
                )
            )
        )
        _searchText = State(initialValue: initialDraft.displayAddress)
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                mapLayer

                VStack(spacing: 12) {
                    searchCard
                    Spacer()
                        .allowsHitTesting(false)
                    confirmButton
                }
                .padding(.horizontal, FGSpacing.lg)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .navigationTitle("Pin venue location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        resolveTask?.cancel()
                        onCancel()
                        dismiss()
                    }
                }
            }
        }
        .task {
#if DEBUG
            print("[InternationalAddressDebug] pinPlacementStarted=true")
#endif
            if initialDraft.coordinate == nil {
                await geocodeSearchTextIfPossible()
            }
            await reverseGeocodePin()
        }
    }

    private var mapLayer: some View {
        MapReader { proxy in
            Map(position: $cameraPosition) {
                Annotation("Venue", coordinate: pinCoordinate) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.system(size: 46))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(FGColor.businessGreen, Color.white)
                        .shadow(color: .black.opacity(0.35), radius: 5, y: 2)
                }
                .annotationTitles(.hidden)
            }
            .mapStyle(.standard(elevation: .realistic, emphasis: .automatic))
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        let dragDistance = hypot(value.translation.width, value.translation.height)
                        guard dragDistance < 18 else { return }
                        guard let coordinate = proxy.convert(value.location, from: .local) else { return }
                        movePin(to: coordinate, shouldCenter: false)
                    }
            )
        }
        .ignoresSafeArea()
    }

    private var searchCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search address or venue location", text: $searchText)
                .textInputAutocapitalization(.words)
                .submitLabel(.search)
                .onSubmit {
                    Task { await geocodeSearchTextIfPossible() }
                }
                .padding(12)
                .background(Color(.systemBackground).opacity(colorScheme == .dark ? 0.70 : 0.92))
                .clipShape(RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))

            HStack(spacing: 8) {
                Button {
                    Task { await geocodeSearchTextIfPossible() }
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isResolving)

                Button {
                    Task { await useCurrentLocation() }
                } label: {
                    Label("Use Current Location", systemImage: "location.fill")
                }
                .buttonStyle(.bordered)
                .disabled(isResolving)
            }
            .font(FGTypography.caption.weight(.semibold))

            Text(statusText)
                .font(FGTypography.caption)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(FGSpacing.md)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.sheet, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FGRadius.sheet, style: .continuous)
                .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.15 : 0.28), lineWidth: 1)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.13), radius: 22, y: 10)
    }

    private var confirmButton: some View {
        Button {
            resolveTask?.cancel()
            draft.latitude = pinCoordinate.latitude
            draft.longitude = pinCoordinate.longitude
            onConfirm(draft)
            dismiss()
        } label: {
            Text("Confirm Venue Location")
                .font(FGTypography.cardTitle.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, FGSpacing.md)
                .background {
                    Capsule(style: .continuous)
                        .fill(FGColor.brandGradient)
                }
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.55 : 0.22), radius: 18, y: 10)
        }
        .buttonStyle(.plain)
    }

    private func movePin(to coordinate: CLLocationCoordinate2D, shouldCenter: Bool) {
        guard CLLocationCoordinate2DIsValid(coordinate) else { return }
#if DEBUG
        print("[InternationalAddressDebug] mapPinMoved=true")
#endif
        withAnimation(.spring(response: 0.42, dampingFraction: 0.84)) {
            pinCoordinate = coordinate
            if shouldCenter {
                cameraPosition = .region(
                    MKCoordinateRegion(
                        center: coordinate,
                        span: MKCoordinateSpan(latitudeDelta: 0.028, longitudeDelta: 0.028)
                    )
                )
            }
        }
        scheduleReverseGeocode()
    }

    private func scheduleReverseGeocode() {
        resolveTask?.cancel()
        resolveTask = Task {
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled else { return }
            await reverseGeocodePin()
        }
    }

    private func geocodeSearchTextIfPossible() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        await MainActor.run {
            isResolving = true
            statusText = "Searching globally..."
        }
        let result = await viewModel.geocodeBusinessVenueAddress(
            query,
            fallbackFormattedAddress: query
        )
        await MainActor.run {
            isResolving = false
            if let result {
                draft.formattedAddress = result.formattedAddress
                movePin(to: result.coordinate, shouldCenter: true)
            } else {
                statusText = "No exact match found. You can still place the pin manually."
            }
        }
    }

    private func useCurrentLocation() async {
        await MainActor.run {
            isResolving = true
            statusText = "Finding current location..."
        }
        let coordinate = await viewModel.fetchCurrentCoordinateForBusinessPin()
        await MainActor.run {
            isResolving = false
            if let coordinate {
                movePin(to: coordinate, shouldCenter: true)
            } else {
                statusText = "Current location is unavailable. Search or tap the map to place the pin."
            }
        }
    }

    private func reverseGeocodePin() async {
        await MainActor.run {
            isResolving = true
            statusText = "Resolving selected location..."
        }
        let result = await viewModel.reverseGeocodeBusinessVenueLocation(for: pinCoordinate)
        await MainActor.run {
            isResolving = false
            draft.latitude = pinCoordinate.latitude
            draft.longitude = pinCoordinate.longitude
            if let line1 = result.addressLine1, !line1.isEmpty { draft.addressLine1 = line1 }
            if let line2 = result.addressLine2, !line2.isEmpty { draft.addressLine2 = line2 }
            if let locality = result.locality, !locality.isEmpty { draft.locality = locality }
            if let region = result.region, !region.isEmpty { draft.region = region }
            if let postal = result.postalCode, !postal.isEmpty { draft.postalCode = postal }
            if let country = result.countryCode, !country.isEmpty { draft.countryCode = country }
            if let formatted = result.formattedAddress, !formatted.isEmpty {
                draft.formattedAddress = formatted
                statusText = formatted
            } else {
                statusText = "Pin selected. You can confirm and edit address text manually."
            }
        }
    }
}

/// Stored country codes on `venue_claims` / owner forms.
enum BusinessLocationCountryPolicy {
    nonisolated static let defaultCountryCode = "US"

    nonisolated private static let legacyAlpha3ToAlpha2: [String: String] = [
        "USA": "US",
        "CAN": "CA",
        "MEX": "MX",
        "FRA": "FR",
        "DEU": "DE",
        "ITA": "IT",
        "ESP": "ES",
        "PRT": "PT",
        "JPN": "JP",
        "CHN": "CN",
        "BRA": "BR",
        "GBR": "GB",
        "AUS": "AU",
        "NZL": "NZ",
        "CHE": "CH",
        "COL": "CO"
    ]

    nonisolated private static let legacyDisplayNames: [String: String] = [
        "OTHER": "Other country"
    ]

    nonisolated static var supportedCountryChoices: [(code: String, label: String)] {
        let locale = Locale.autoupdatingCurrent
        let english = Locale(identifier: "en_US")
        var rows = Locale.Region.isoRegions.compactMap { region -> (code: String, label: String)? in
            let raw = region.identifier
            let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard code.count == 2 else { return nil }
            let label = locale.localizedString(forRegionCode: code)
                ?? english.localizedString(forRegionCode: code)
                ?? code
            return (code: code, label: label)
        }
        rows.append((code: "OTHER", label: legacyDisplayNames["OTHER"] ?? "Other country"))
        return rows.sorted {
            $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
    }

    nonisolated static var supportedCountryCodes: Set<String> {
        Set(supportedCountryChoices.map(\.code))
            .union(legacyAlpha3ToAlpha2.keys)
            .union(legacyDisplayNames.keys)
    }

    /// When more than one country is supported, the form shows an editable `Picker`; otherwise the value stays fixed at default.
    nonisolated static var showsCountryPicker: Bool { supportedCountryChoices.count > 1 }

    nonisolated static func normalizedStoredCountryCode(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if t.isEmpty { return "" }
        if let mapped = legacyAlpha3ToAlpha2[t] { return mapped }
        if supportedCountryCodes.contains(t) { return t }
        return t
    }

    nonisolated static func countryName(for code: String) -> String {
        let normalized = normalizedStoredCountryCode(code)
        if let legacy = legacyDisplayNames[normalized] { return legacy }
        return Locale.autoupdatingCurrent.localizedString(forRegionCode: normalized)
            ?? Locale(identifier: "en_US").localizedString(forRegionCode: normalized)
            ?? normalized
    }

    nonisolated static func labels(for code: String) -> BusinessLocationAddressLabels {
        switch normalizedStoredCountryCode(code) {
        case "US":
            return BusinessLocationAddressLabels(locality: "City", region: "State", postalCode: "Postal code", regionRequired: true, localityRequired: true)
        case "CA":
            return BusinessLocationAddressLabels(locality: "City", region: "Province", postalCode: "Postal Code", regionRequired: false, localityRequired: true)
        case "JP":
            return BusinessLocationAddressLabels(locality: "Locality / City / Ward", region: "Prefecture", postalCode: "Postal code", regionRequired: false, localityRequired: false)
        case "CN":
            return BusinessLocationAddressLabels(locality: "Locality / City / District", region: "Province", postalCode: "Postal code", regionRequired: false, localityRequired: false)
        case "KR":
            return BusinessLocationAddressLabels(locality: "Locality / City / District", region: "Province / Region", postalCode: "Postal code", regionRequired: false, localityRequired: false)
        case "AU", "NZ":
            return BusinessLocationAddressLabels(locality: "Locality / City / Suburb", region: "State / Territory / Region", postalCode: "Postal code", regionRequired: false, localityRequired: true)
        default:
            return BusinessLocationAddressLabels(locality: "Locality / City", region: "Region / State / Province", postalCode: "Postal code", regionRequired: false, localityRequired: false)
        }
    }

    nonisolated static func clearDefaultRegionIfNeeded(_ region: inout String, whenCountryChangesTo country: String) {
        let normalized = normalizedStoredCountryCode(country)
        guard normalized != "US" else { return }
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
    nonisolated static func formattedAddress(
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
        case "JP", "CN", "KR", "TW", "HK", "MO":
            return joined([country, postal, reg, city, l1, l2], separator: ", ")
        case _ where europeCountryCodes.contains(countryCode):
            let cityLine = joined([postal, city], separator: " ")
            return joined([l1, l2, cityLine, reg, country], separator: ", ")
        default:
            let regionPostal = joined([reg, postal], separator: " ")
            return joined([l1, l2, city, regionPostal, country], separator: ", ")
        }
    }

    nonisolated static func geocodeQuery(
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

    nonisolated private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func joined(_ values: [String], separator: String) -> String {
        values.filter { !$0.isEmpty }.joined(separator: separator)
    }

    nonisolated private static let europeCountryCodes: Set<String> = [
        "AL", "AD", "AT", "BY", "BE", "BA", "BG", "HR", "CY", "CZ", "DK", "EE", "FI", "FR",
        "DE", "GR", "HU", "IS", "IE", "IT", "XK", "LV", "LI", "LT", "LU", "MT", "MD", "MC",
        "ME", "NL", "MK", "NO", "PL", "PT", "RO", "RU", "SM", "RS", "SK", "SI", "ES", "SE",
        "CH", "UA", "GB", "VA"
    ]
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
            .onAppear {
#if DEBUG
                print("[InternationalAddressDebug] unicodeSupported=true")
                print("[InternationalAddressDebug] countryPickerExpanded=true")
                print("[InternationalAddressDebug] internationalFormattingEnabled=true")
#endif
                countryCode = BusinessLocationCountryPolicy.normalizedStoredCountryCode(countryCode)
            }
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
        let code = BusinessLocationCountryPolicy.normalizedStoredCountryCode(countryCode)
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
        if BusinessLocationCountryPolicy.normalizedStoredCountryCode(countryCode) == "US" {
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
