import Foundation
import SwiftUI

// MARK: - Dial metadata (major markets; extend over time)

enum BusinessPhoneFields {
    struct DialCountry: Identifiable, Hashable {
        /// ISO 3166-1 alpha-2
        let id: String
        let name: String
        let flag: String
        /// ITU dialing prefix including `+` (e.g. `+1`, `+44`).
        let dialCode: String

        var menuLabel: String { "\(flag)  \(dialCode)  \(name)" }
        var compactLabel: String { "\(flag) \(dialCode)" }
    }

    static let defaultISO = "US"

    /// Curated list; `+1` appears twice (US / CA). Parsing `+1…` defaults to **US** when ambiguous.
    static let countries: [DialCountry] = [
        DialCountry(id: "US", name: "United States", flag: "🇺🇸", dialCode: "+1"),
        DialCountry(id: "CA", name: "Canada", flag: "🇨🇦", dialCode: "+1"),
        DialCountry(id: "GB", name: "United Kingdom", flag: "🇬🇧", dialCode: "+44"),
        DialCountry(id: "FR", name: "France", flag: "🇫🇷", dialCode: "+33"),
        DialCountry(id: "DE", name: "Germany", flag: "🇩🇪", dialCode: "+49"),
        DialCountry(id: "ES", name: "Spain", flag: "🇪🇸", dialCode: "+34"),
        DialCountry(id: "IT", name: "Italy", flag: "🇮🇹", dialCode: "+39"),
        DialCountry(id: "NL", name: "Netherlands", flag: "🇳🇱", dialCode: "+31"),
        DialCountry(id: "BE", name: "Belgium", flag: "🇧🇪", dialCode: "+32"),
        DialCountry(id: "CH", name: "Switzerland", flag: "🇨🇭", dialCode: "+41"),
        DialCountry(id: "AT", name: "Austria", flag: "🇦🇹", dialCode: "+43"),
        DialCountry(id: "IE", name: "Ireland", flag: "🇮🇪", dialCode: "+353"),
        DialCountry(id: "PT", name: "Portugal", flag: "🇵🇹", dialCode: "+351"),
        DialCountry(id: "SE", name: "Sweden", flag: "🇸🇪", dialCode: "+46"),
        DialCountry(id: "NO", name: "Norway", flag: "🇳🇴", dialCode: "+47"),
        DialCountry(id: "DK", name: "Denmark", flag: "🇩🇰", dialCode: "+45"),
        DialCountry(id: "FI", name: "Finland", flag: "🇫🇮", dialCode: "+358"),
        DialCountry(id: "PL", name: "Poland", flag: "🇵🇱", dialCode: "+48"),
        DialCountry(id: "CZ", name: "Czechia", flag: "🇨🇿", dialCode: "+420"),
        DialCountry(id: "GR", name: "Greece", flag: "🇬🇷", dialCode: "+30"),
        DialCountry(id: "TR", name: "Türkiye", flag: "🇹🇷", dialCode: "+90"),
        DialCountry(id: "IL", name: "Israel", flag: "🇮🇱", dialCode: "+972"),
        DialCountry(id: "AE", name: "United Arab Emirates", flag: "🇦🇪", dialCode: "+971"),
        DialCountry(id: "SA", name: "Saudi Arabia", flag: "🇸🇦", dialCode: "+966"),
        DialCountry(id: "ZA", name: "South Africa", flag: "🇿🇦", dialCode: "+27"),
        DialCountry(id: "NG", name: "Nigeria", flag: "🇳🇬", dialCode: "+234"),
        DialCountry(id: "KE", name: "Kenya", flag: "🇰🇪", dialCode: "+254"),
        DialCountry(id: "EG", name: "Egypt", flag: "🇪🇬", dialCode: "+20"),
        DialCountry(id: "IN", name: "India", flag: "🇮🇳", dialCode: "+91"),
        DialCountry(id: "CN", name: "China", flag: "🇨🇳", dialCode: "+86"),
        DialCountry(id: "JP", name: "Japan", flag: "🇯🇵", dialCode: "+81"),
        DialCountry(id: "KR", name: "South Korea", flag: "🇰🇷", dialCode: "+82"),
        DialCountry(id: "TW", name: "Taiwan", flag: "🇹🇼", dialCode: "+886"),
        DialCountry(id: "HK", name: "Hong Kong", flag: "🇭🇰", dialCode: "+852"),
        DialCountry(id: "SG", name: "Singapore", flag: "🇸🇬", dialCode: "+65"),
        DialCountry(id: "MY", name: "Malaysia", flag: "🇲🇾", dialCode: "+60"),
        DialCountry(id: "TH", name: "Thailand", flag: "🇹🇭", dialCode: "+66"),
        DialCountry(id: "VN", name: "Vietnam", flag: "🇻🇳", dialCode: "+84"),
        DialCountry(id: "PH", name: "Philippines", flag: "🇵🇭", dialCode: "+63"),
        DialCountry(id: "ID", name: "Indonesia", flag: "🇮🇩", dialCode: "+62"),
        DialCountry(id: "AU", name: "Australia", flag: "🇦🇺", dialCode: "+61"),
        DialCountry(id: "NZ", name: "New Zealand", flag: "🇳🇿", dialCode: "+64"),
        DialCountry(id: "MX", name: "Mexico", flag: "🇲🇽", dialCode: "+52"),
        DialCountry(id: "BR", name: "Brazil", flag: "🇧🇷", dialCode: "+55"),
        DialCountry(id: "AR", name: "Argentina", flag: "🇦🇷", dialCode: "+54"),
        DialCountry(id: "CL", name: "Chile", flag: "🇨🇱", dialCode: "+56"),
        DialCountry(id: "CO", name: "Colombia", flag: "🇨🇴", dialCode: "+57"),
        DialCountry(id: "RU", name: "Russia", flag: "🇷🇺", dialCode: "+7")
    ]

    static var countriesSortedForPicker: [DialCountry] {
        countries.sorted { a, b in
            if a.dialCode != b.dialCode { return a.dialCode < b.dialCode }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// One ISO per ITU digit prefix (longest match wins at parse time). `+1` resolves to **US** first in ``countries``.
    private static var uniqueDialDigitPrefixesLongestFirst: [(digits: String, iso: String)] {
        var seen = Set<String>()
        var out: [(String, String)] = []
        for c in countries {
            let d = digitsOnly(String(c.dialCode.dropFirst()))
            guard !d.isEmpty, !seen.contains(d) else { continue }
            seen.insert(d)
            out.append((d, c.id))
        }
        return out.sorted { lhs, rhs in lhs.0.count > rhs.0.count }
    }

    static func dialCode(iso: String) -> String {
        let u = iso.uppercased()
        return countries.first(where: { $0.id == u })?.dialCode ?? "+1"
    }

    static func country(iso: String) -> DialCountry? {
        let u = iso.uppercased()
        return countries.first(where: { $0.id == u })
    }

    /// Digits only (Unicode decimal).
    static func digitsOnly(_ s: String) -> String {
        s.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.map(String.init).joined()
    }

    /// Strips duplicate leading `+` from a full stored value.
    static func normalizePlusPrefix(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasPrefix("++") {
            t = String(t.dropFirst())
        }
        return t
    }

    /// Characters allowed while typing the **national** portion (no second `+` after country is chosen in UI).
    static func sanitizeLocalTyping(_ raw: String) -> String {
        let allowed = CharacterSet(charactersIn: "0123456789 ()-.")
        return String(raw.unicodeScalars.filter { allowed.contains($0) })
    }

    /// Builds one DB string: `+<country><nationaldigits>` (no spaces). Strips a redundant leading national `1` for NANP when dial is `+1`.
    static func combinedStorage(iso: String, local: String) -> String {
        let dial = dialCode(iso: iso)
        var national = digitsOnly(local)
        let dialDigits = digitsOnly(String(dial.dropFirst()))
        if dial == "+1", national.first == "1", national.count == 11 {
            national = String(national.dropFirst())
        }
        if national.hasPrefix(dialDigits) {
            national = String(national.dropFirst(dialDigits.count))
        }
        if national.isEmpty { return dial }
        return dial + national
    }

    /// Parses a stored phone (legacy local-only or E.164-ish) into picker ISO + national digits for the text field.
    static func parse(stored: String) -> (iso: String, localDigits: String) {
        let t = normalizePlusPrefix(stored)
        if t.isEmpty { return (defaultISO, "") }

        if !t.hasPrefix("+") {
            let d = digitsOnly(t)
            if d.isEmpty { return (defaultISO, "") }
            if d.count == 10 { return (defaultISO, d) }
            if d.count == 11, d.first == "1" { return (defaultISO, String(d.dropFirst())) }
            return (defaultISO, d)
        }

        let allAfterPlus = digitsOnly(String(t.dropFirst()))
        if allAfterPlus.isEmpty { return (defaultISO, "") }

        for pair in uniqueDialDigitPrefixesLongestFirst {
            guard allAfterPlus.hasPrefix(pair.0) else { continue }
            var rest = String(allAfterPlus.dropFirst(pair.0.count))
            if pair.0 == "1" {
                if rest.count == 11, rest.first == "1" { rest = String(rest.dropFirst()) }
                if rest.count == 10 { return ("US", rest) }
            }
            return (pair.1, rest)
        }

        return (defaultISO, allAfterPlus)
    }

    /// Human-friendly display (e.g. `+1 801-555-1234` for NANP 10-digit national).
    static func displayString(fromStored stored: String) -> String {
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        let parsed = parse(stored: trimmed)
        let dial = dialCode(iso: parsed.iso)
        let local = parsed.localDigits
        if dial == "+1", local.count == 10 {
            let a = local.prefix(3)
            let b = local.dropFirst(3).prefix(3)
            let c = local.dropFirst(6)
            return "\(dial) \(a)-\(b)-\(c)"
        }
        if local.isEmpty { return dial }
        return "\(dial) \(local)"
    }

    /// Path for `tel:` URLs (digits only, includes country code).
    static func telDigits(fromStored stored: String) -> String {
        let parsed = parse(stored: stored.trimmingCharacters(in: .whitespacesAndNewlines))
        return digitsOnly(combinedStorage(iso: parsed.iso, local: parsed.localDigits))
    }

    static func storageValidationError(iso: String, local: String) -> String? {
        let d = digitsOnly(combinedStorage(iso: iso, local: local))
        if d.isEmpty { return "Enter a phone number." }
        if d.count < 8 { return "Phone number looks too short." }
        if d.count > 15 { return "Phone number looks too long." }
        return nil
    }

    static func storageValidationError(combined: String) -> String? {
        let t = combined.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        let p = parse(stored: t)
        return storageValidationError(iso: p.iso, local: p.localDigits)
    }
}

// MARK: - SwiftUI: dial picker + local field (FanGeo business chrome)

struct BusinessPhoneNumberField: View {
    @Binding var dialISO: String
    @Binding var localNumber: String
    /// Placeholder for the national-number field (left column shows dial code, e.g. `🇺🇸 +1`).
    var localPlaceholder: String = "Mobile or business line"

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var localFocused: Bool
    @State private var showDialPicker = false
    @State private var dialSearch = ""

    private var selectedCountry: BusinessPhoneFields.DialCountry? {
        BusinessPhoneFields.country(iso: dialISO)
    }

    private var filteredCountries: [BusinessPhoneFields.DialCountry] {
        let q = dialSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = BusinessPhoneFields.countriesSortedForPicker
        if q.isEmpty { return base }
        return base.filter {
            $0.name.lowercased().contains(q)
                || $0.dialCode.lowercased().contains(q)
                || $0.id.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Phone")
                .font(FGTypography.metadata.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))

            HStack(alignment: .center, spacing: 10) {
                Button {
                    dialSearch = ""
                    showDialPicker = true
                } label: {
                    HStack(spacing: 6) {
                        Text(selectedCountry?.compactLabel ?? "🇺🇸 +1")
                            .font(FGTypography.cardTitle)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(FGColor.mutedText(colorScheme))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 14)
                    .frame(minWidth: 96)
                    .background(FGAdaptiveSurface.controlFill)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Country dialing code")

                TextField(localPlaceholder, text: $localNumber)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                    .focused($localFocused)
                    .onChange(of: localNumber) { _, newValue in
                        let s = BusinessPhoneFields.sanitizeLocalTyping(newValue)
                        if s != newValue {
                            localNumber = s
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(FGAdaptiveSurface.controlFill)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .sheet(isPresented: $showDialPicker) {
            NavigationStack {
                List(filteredCountries) { c in
                    Button {
                        dialISO = c.id
                        showDialPicker = false
                    } label: {
                        HStack {
                            Text(c.menuLabel)
                                .font(FGTypography.body)
                                .foregroundStyle(FGColor.primaryText(colorScheme))
                            Spacer()
                            if c.id == dialISO.uppercased() {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }
                .searchable(text: $dialSearch, prompt: "Search country or code")
                .navigationTitle("Dialing code")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { showDialPicker = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(FGAdaptiveSurface.sheetRoot)
        }
    }
}
