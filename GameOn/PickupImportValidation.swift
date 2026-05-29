import CoreLocation
import Foundation

enum PickupBulkImportRowStatus: String, Equatable {
    case valid
    case warning
    case failed

    var isImportable: Bool {
        self == .valid
    }

    var displayTitle: String {
        switch self {
        case .valid:
            return "Ready"
        case .warning:
            return "Warning"
        case .failed:
            return "Error"
        }
    }
}

struct PickupBulkImportPreparedRow: Identifiable, Equatable {
    let id = UUID()
    let rowNumber: Int
    let title: String
    let sport: String
    let description: String?
    let skillLevel: String
    let gameStartAt: Date?
    let endTime: Date?
    let address: String
    let city: String
    let state: String
    let playersNeeded: Int?
    let maxPlayers: Int?
    let playEnvironment: String
    let participantPreference: String
    let ageMin: Int?
    let ageMax: Int?
    let isFree: Bool
    let entryFeeAmount: Double?
    let coordinate: CLLocationCoordinate2D?
    let gameType: GameType
    let leagueName: String?
    let homeTeam: String?
    let awayTeam: String?
    let season: String?
    let division: String?
    let warnings: [String]
    let errors: [String]

    var status: PickupBulkImportRowStatus {
        if !errors.isEmpty { return .failed }
        if !warnings.isEmpty { return .warning }
        return .valid
    }

    var locationLine: String {
        [address, city, state].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    var ageRangeDisplayText: String? {
        PickupGameAgeRangeFormatter.ageRangeText(min: ageMin, max: ageMax)
    }

    static func == (lhs: PickupBulkImportPreparedRow, rhs: PickupBulkImportPreparedRow) -> Bool {
        lhs.id == rhs.id
    }
}

struct PickupBulkImportSummary: Equatable {
    let validCount: Int
    let warningCount: Int
    let failedCount: Int

    var importableCount: Int {
        validCount
    }

    var totalCount: Int {
        validCount + warningCount + failedCount
    }
}

enum PickupBulkImportValidator {
    static func summary(for rows: [PickupBulkImportPreparedRow]) -> PickupBulkImportSummary {
        PickupBulkImportSummary(
            validCount: rows.filter { $0.status == .valid }.count,
            warningCount: rows.filter { $0.status == .warning }.count,
            failedCount: rows.filter { $0.status == .failed }.count
        )
    }

    @MainActor
    static func validate(rawRows: [PickupBulkImportRawRow], viewModel: MapViewModel) async -> [PickupBulkImportPreparedRow] {
#if DEBUG
        print("[PickupBulkValidation] started rows=\(rawRows.count)")
#endif
        let duplicateKeys = duplicateRowKeys(rawRows)
        var output: [PickupBulkImportPreparedRow] = []
        output.reserveCapacity(rawRows.count)

        for raw in rawRows {
            output.append(await validate(raw: raw, duplicateKeys: duplicateKeys, viewModel: viewModel))
        }

#if DEBUG
        let summary = summary(for: output)
        print("[PickupBulkValidation] validRows=\(summary.validCount)")
        print("[PickupBulkValidation] warningRows=\(summary.warningCount)")
        print("[PickupBulkValidation] failedRows=\(summary.failedCount)")
#endif
        return output
    }

    @MainActor
    private static func validate(
        raw: PickupBulkImportRawRow,
        duplicateKeys: Set<String>,
        viewModel: MapViewModel
    ) async -> PickupBulkImportPreparedRow {
        var errors: [String] = []
        var warnings: [String] = []

        let title = raw.value("title")
        let sportRaw = raw.value("sport")
        let description = raw.value("description")
        let skillRaw = raw.value("skill_level")
        let startRaw = raw.value("game_start_at")
        let endRaw = raw.value("end_time")
        let address = raw.value("address")
        let city = raw.value("city")
        let state = raw.value("state")
        let playersRaw = raw.value("players_needed")
        let maxPlayersRaw = raw.value("max_players")
        let playEnvironmentRaw = raw.value("play_environment")
        let participantPreferenceRaw = raw.value("participant_preference")
        let minAgeCell = readAgeColumn(from: raw, header: "min_age")
        let maxAgeCell = readAgeColumn(from: raw, header: "max_age")
        let isFreeRaw = raw.value("is_free")
        let entryFeeRaw = raw.value("entry_fee_amount")
        let gameFormatRaw = raw.value("game_format")
        let leagueName = raw.value("league_name")
        let homeTeam = raw.value("home_team")
        let awayTeam = raw.value("away_team")
        let season = raw.value("season")
        let division = raw.value("division")

        appendMissing("title", title, to: &errors)
        appendMissing("sport", sportRaw, to: &errors)
        appendMissing("skill_level", skillRaw, to: &errors)
        appendMissing("game_start_at", startRaw, to: &errors)
        appendMissing("address", address, to: &errors)
        appendMissing("city", city, to: &errors)
        appendMissing("state", state, to: &errors)
        appendMissing("players_needed", playersRaw, to: &errors)

        let sport = canonicalSport(from: sportRaw)
        if sport == nil, !sportRaw.isEmpty {
            errors.append(invalidValueMessage(field: "sport", value: sportRaw, guidance: "Allowed sports: \(allowedSportLabels())."))
        }

        let gameFormat = canonicalGameFormat(from: gameFormatRaw)
        if gameFormat == nil, !gameFormatRaw.isEmpty {
            errors.append(invalidValueMessage(field: "game_format", value: gameFormatRaw, guidance: "Use: pickup, practice, or scrimmage."))
        }

        let skillLevel = skillRaw.isEmpty ? PickupGameSkillLevel.casual.rawValue : canonicalSkillLevel(from: skillRaw)
        if skillLevel == nil {
            errors.append(invalidValueMessage(field: "skill_level", value: skillRaw, guidance: "Use: \(allowedSkillLevelValues())."))
        }

        let start = parseDateTime(startRaw)
#if DEBUG
        print("[PickupBulkValidation] rawStart=\(startRaw)")
        print("[PickupBulkValidation] parsedStart=\(debugDateString(start))")
#endif
        if start == nil, !startRaw.isEmpty {
            errors.append("Invalid game_start_at date.")
        } else if let start, start <= Date() {
            errors.append(VenueOwnerGameScheduleValidation.futureDateTimeMessage)
        }

        let end = parseEndTime(endRaw, start: start)
#if DEBUG
        print("[PickupBulkValidation] rawEnd=\(endRaw)")
        print("[PickupBulkValidation] parsedEnd=\(debugDateString(end))")
#endif
        if end == nil, !endRaw.isEmpty {
            errors.append("Invalid end_time.")
        } else if let start, let end, end <= start {
            errors.append("end_time must be after game_start_at.")
        }

        let playersNeeded = Int(playersRaw)
        if playersNeeded == nil, !playersRaw.isEmpty {
            errors.append("players_needed must be numeric.")
        } else if let playersNeeded, !(1...20).contains(playersNeeded) {
            errors.append("players_needed must be between 1 and 20.")
        }

        var maxPlayers: Int?
        if maxPlayersRaw.isEmpty {
            maxPlayers = nil
        } else if let parsed = Int(maxPlayersRaw) {
            maxPlayers = parsed
            if !(1...100).contains(parsed) {
                errors.append("max_players must be between 1 and 100.")
            } else if let playersNeeded, parsed < playersNeeded {
                errors.append("max_players must be at least players_needed.")
            }
        } else {
            errors.append("max_players must be numeric when provided.")
        }

        let playEnvironment = playEnvironmentRaw.isEmpty ? PickupPlayEnvironment.either.rawValue : canonicalPlayEnvironment(from: playEnvironmentRaw)
        if playEnvironment == nil {
            errors.append(invalidValueMessage(field: "play_environment", value: playEnvironmentRaw, guidance: "Use: indoor, outdoor, or either."))
        }

        let participantPreference = canonicalParticipantPreference(from: participantPreferenceRaw)
        if participantPreference == nil, !participantPreferenceRaw.isEmpty {
            errors.append(invalidValueMessage(field: "participant_preference", value: participantPreferenceRaw, guidance: "Use: everyone, men, women, coed, kids, teens, adults, or seniors."))
        }

        let isFree = parseOptionalImportBoolean(isFreeRaw)
        if isFree == nil, !isFreeRaw.isEmpty {
            errors.append(invalidValueMessage(field: "is_free", value: isFreeRaw, guidance: "Use: TRUE or FALSE."))
        }

        var entryFeeAmount: Double?
        if !entryFeeRaw.isEmpty {
            if let parsed = Double(entryFeeRaw), parsed >= 0, parsed <= 999_999 {
                entryFeeAmount = (parsed * 100.0).rounded() / 100.0
            } else {
                errors.append("entry_fee_amount must be a valid number.")
            }
        }
        if isFree == false && (entryFeeAmount ?? 0) <= 0 {
            errors.append("entry_fee_amount is required when is_free is FALSE.")
        }

        let ageRange = parseImportAgeRange(
            minRaw: minAgeCell.normalizedValue,
            maxRaw: maxAgeCell.normalizedValue,
            errors: &errors
        )
        let ageMin = ageRange.min
        let ageMax = ageRange.max

        if duplicateKeys.contains(duplicateKey(for: raw)) {
            errors.append("Duplicate row in import file.")
        }

#if DEBUG
        if !errors.isEmpty {
            logAgeDebug(
                rowNumber: raw.rowNumber,
                minAgeCell: minAgeCell,
                maxAgeCell: maxAgeCell,
                participantPreference: participantPreferenceRaw,
                isFree: raw.value("is_free"),
                entryFee: raw.value("entry_fee_amount"),
                maxPlayers: maxPlayersRaw,
                endTime: endRaw
            )
        }
#endif

        var coordinate: CLLocationCoordinate2D?
        if errors.isEmpty {
            let addressLine = [address, city, state].filter { !$0.isEmpty }.joined(separator: ", ")
#if DEBUG
            print("[PickupBulkGeocode] row=\(raw.rowNumber) address=\(addressLine)")
#endif
            if let resolved = await viewModel.geocodeAddress(addressLine) {
                coordinate = resolved
#if DEBUG
                print("[PickupBulkGeocode] row=\(raw.rowNumber) success=true latitude=\(resolved.latitude) longitude=\(resolved.longitude)")
#endif
            } else {
#if DEBUG
                print("[PickupBulkGeocode] row=\(raw.rowNumber) success=false")
#endif
                errors.append("Invalid address.")
            }
        }

        if errors.isEmpty,
           let start,
           let coordinate {
            let conflictEnd = end ?? PickupGameModels.defaultPickupEndTime(forStart: start)
            do {
                if try await viewModel.findOverlappingPickupGameAtLocation(
                    newStart: start,
                    newEnd: conflictEnd,
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude,
                    address: address,
                    city: city,
                    state: state
                ) != nil {
                    errors.append("Another pickup game already exists at this location and time.")
                }
            } catch {
                warnings.append("Could not check for existing games at this location.")
            }
        }

        return PickupBulkImportPreparedRow(
            rowNumber: raw.rowNumber,
            title: title,
            sport: sport ?? sportRaw,
            description: description,
            skillLevel: skillLevel ?? PickupGameSkillLevel.casual.rawValue,
            gameStartAt: start,
            endTime: end,
            address: address,
            city: city,
            state: state,
            playersNeeded: playersNeeded,
            maxPlayers: maxPlayers,
            playEnvironment: playEnvironment ?? PickupPlayEnvironment.either.rawValue,
            participantPreference: participantPreference ?? PickupParticipantPreference.everyone.rawValue,
            ageMin: ageMin,
            ageMax: ageMax,
            isFree: isFree ?? true,
            entryFeeAmount: entryFeeAmount,
            coordinate: coordinate,
            gameType: gameFormat ?? .pickup,
            leagueName: leagueName.isEmpty ? nil : leagueName,
            homeTeam: homeTeam.isEmpty ? nil : homeTeam,
            awayTeam: awayTeam.isEmpty ? nil : awayTeam,
            season: season.isEmpty ? nil : season,
            division: division.isEmpty ? nil : division,
            warnings: warnings,
            errors: errors
        )
    }

    private static func appendMissing(_ name: String, _ value: String, to errors: inout [String]) {
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Missing \(name).")
        }
    }

    private static func canonicalSport(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = normalizeToken(trimmed)
        for sport in AppSportCatalog.formPickerSportsOrdered {
            if sport.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
                || AppSportCatalog.displayLabel(forSportToken: sport).localizedCaseInsensitiveCompare(trimmed) == .orderedSame
                || normalizeToken(sport) == normalized
                || normalizeToken(AppSportCatalog.displayLabel(forSportToken: sport)) == normalized
                || sportImportAliases(for: sport).contains(normalized) {
                return sport
            }
        }
        return nil
    }

    private static func sportImportAliases(for sport: String) -> Set<String> {
        switch normalizeToken(sport) {
        case "breakdance":
            return ["breakdance", "breaking", "breakdancing", "urbandance", "dance"]
        case "ballet":
            return ["ballet", "classicalballet", "performingarts", "dance"]
        default:
            return []
        }
    }

    private static func canonicalSkillLevel(from raw: String) -> String? {
        let normalized = normalizeToken(raw)
        guard !normalized.isEmpty else { return nil }
        for level in PickupGameSkillLevel.allCases {
            if normalizeToken(level.rawValue) == normalized || normalizeToken(level.displayTitle) == normalized {
                return level.rawValue
            }
        }
        return nil
    }

    private static func canonicalPlayEnvironment(from raw: String) -> String? {
        let normalized = normalizeToken(raw)
        guard !normalized.isEmpty else { return PickupPlayEnvironment.either.rawValue }
        for environment in PickupPlayEnvironment.allCases {
            if normalizeToken(environment.rawValue) == normalized
                || normalizeToken(environment.displayTitle) == normalized
                || normalizeToken(environment.shortLabel) == normalized {
                return environment.rawValue
            }
        }
        return nil
    }

    private static func canonicalGameFormat(from raw: String) -> GameType? {
        let normalized = normalizeToken(raw)
        guard !normalized.isEmpty else { return .pickup }
        for type in GameType.allCases {
            if normalizeToken(type.rawValue) == normalized || normalizeToken(type.displayTitle) == normalized {
                return type
            }
        }
        return nil
    }

    private static func canonicalParticipantPreference(from raw: String) -> String? {
        let normalized = normalizeToken(raw)
        guard !normalized.isEmpty else { return PickupParticipantPreference.everyone.rawValue }
        switch normalized {
        case "coed", "all", "all_welcome", "everyone":
            return PickupParticipantPreference.everyone.rawValue
        case "men", "male", "men_only", "males":
            return PickupParticipantPreference.men_only.rawValue
        case "women", "female", "women_only", "females":
            return PickupParticipantPreference.women_only.rawValue
        case "kids", "kids_only", "children", "youth":
            return PickupParticipantPreference.kids_only.rawValue
        case "teens", "teen", "teenagers", "teens_welcome":
            return PickupParticipantPreference.teens_welcome.rawValue
        case "adults", "adult", "adults_only":
            return PickupParticipantPreference.adults_only.rawValue
        case "seniors", "seniors_welcome":
            return PickupParticipantPreference.seniors_welcome.rawValue
        default:
            break
        }
        for preference in PickupParticipantPreference.allCases {
            if normalizeToken(preference.rawValue) == normalized
                || normalizeToken(preference.displayTitle) == normalized
                || normalizeToken(preference.shortLabel) == normalized {
                return preference.rawValue
            }
        }
        return nil
    }

    private static func parseOptionalImportBoolean(_ raw: String) -> Bool? {
        let normalized = normalizeToken(raw)
        guard !normalized.isEmpty else { return true }
        switch normalized {
        case "true":
            return true
        case "false":
            return false
        default:
            return nil
        }
    }

    private static func invalidValueMessage(field: String, value: String, guidance: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Invalid \(field) \"\(trimmed)\". \(guidance)"
    }

    private static func allowedSportLabels() -> String {
        AppSportCatalog.formPickerSportsOrdered
            .map { AppSportCatalog.displayLabel(forSportToken: $0) }
            .joined(separator: ", ")
    }

    private static func allowedSkillLevelValues() -> String {
        listText(PickupGameSkillLevel.allCases.map(\.rawValue))
    }

    private static func listText(_ values: [String]) -> String {
        switch values.count {
        case 0:
            return ""
        case 1:
            return values[0]
        case 2:
            return "\(values[0]) or \(values[1])"
        default:
            return values.dropLast().joined(separator: ", ") + ", or \(values.last ?? "")"
        }
    }

    private enum AgeColumnKind {
        case minimum
        case maximum

        var displayName: String {
            switch self {
            case .minimum: return "Minimum age"
            case .maximum: return "Maximum age"
            }
        }
    }

    private static func parseImportAgeRange(
        minRaw: String,
        maxRaw: String,
        errors: inout [String]
    ) -> (min: Int?, max: Int?) {
        let minValue = normalizedImportAgeRangeValue(minRaw)
        let maxValue = normalizedImportAgeRangeValue(maxRaw)
        guard !minValue.isEmpty, !maxValue.isEmpty else {
            return (nil, nil)
        }

        let minAge = parseRequiredImportAge(minValue, kind: .minimum, errors: &errors)
        let maxAge = parseRequiredImportAge(maxValue, kind: .maximum, errors: &errors)
        guard let minAge, let maxAge else {
            return (nil, nil)
        }
        if minAge > maxAge {
            errors.append("Minimum age \(minAge) can’t be greater than maximum age \(maxAge).")
            return (nil, nil)
        }
        return (minAge, maxAge)
    }

    private static func parseRequiredImportAge(_ raw: String, kind: AgeColumnKind, errors: inout [String]) -> Int? {
        guard let parsed = Int(raw) else {
            errors.append("\(kind.displayName) \"\(raw)\" must be a number. Use numbers only for age ranges (example: 8, 18, 55).")
            return nil
        }
        return parsed
    }

    private static func normalizedImportAgeRangeValue(_ raw: String) -> String {
        let trimmed = normalizedOptionalAgeField(raw)
        let lowered = trimmed.lowercased()
        if lowered == "true" || lowered == "false" {
            return ""
        }
        return trimmed
    }

    private struct AgeColumnRead {
        let headerUsed: String
        let rawValue: String
        let normalizedValue: String
    }

    private static func readAgeColumn(
        from row: PickupBulkImportRawRow,
        header: String
    ) -> AgeColumnRead {
        guard row.hasSourceHeader(header) else {
            return AgeColumnRead(
                headerUsed: "(missing)",
                rawValue: "",
                normalizedValue: ""
            )
        }

        let raw = row.rawValue(header) ?? ""
        let normalized = normalizedOptionalAgeField(raw)
        logBooleanAgeMappingBugIfNeeded(header: header, rawValue: raw, normalizedValue: normalized)
        return AgeColumnRead(
            headerUsed: header,
            rawValue: raw,
            normalizedValue: normalized
        )
    }

    private static func normalizedOptionalAgeField(_ raw: String) -> String {
        let withoutInvisibleWhitespace = raw
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{200C}", with: "")
            .replacingOccurrences(of: "\u{200D}", with: "")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
        let trimmed = withoutInvisibleWhitespace.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        if lowered.isEmpty
            || lowered == "\"\""
            || lowered == "''"
            || lowered == "nil"
            || lowered == "null"
            || lowered == "nsnull"
            || lowered == "<null>"
            || lowered == "(null)"
            || lowered == "undefined"
            || lowered == "n/a"
            || lowered == "na"
            || lowered == "-"
            || lowered == "—"
            || lowered == "–" {
            return ""
        }
        if lowered == "true" || lowered == "false" {
            return ""
        }
        return trimmed
    }

    private static func logBooleanAgeMappingBugIfNeeded(header: String, rawValue: String, normalizedValue: String) {
        let token = normalizedValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rawToken = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard token == "true" || token == "false" || rawToken == "true" || rawToken == "false" else { return }
#if DEBUG
        print("[PickupImportColumnBug] age field mapped to boolean column header=\(header) rawValue=\(rawValue)")
#endif
    }

#if DEBUG
    private static func debugAgeValue(_ raw: String) -> String {
        raw.isEmpty ? "(empty)" : raw
    }

    private static func logAgeDebug(
        rowNumber: Int,
        minAgeCell: AgeColumnRead,
        maxAgeCell: AgeColumnRead,
        participantPreference: String,
        isFree: String,
        entryFee: String,
        maxPlayers: String,
        endTime: String
    ) {
        print("[PickupImportAgeDebug] row=\(rowNumber)")
        print("[PickupImportAgeDebug] minHeaderUsed=\(minAgeCell.headerUsed)")
        print("[PickupImportAgeDebug] maxHeaderUsed=\(maxAgeCell.headerUsed)")
        print("[PickupImportAgeDebug] rawMinAge=\(debugAgeValue(minAgeCell.rawValue))")
        print("[PickupImportAgeDebug] rawMaxAge=\(debugAgeValue(maxAgeCell.rawValue))")
        print("[PickupImportAgeDebug] normalizedMinAge=\(debugAgeValue(minAgeCell.normalizedValue))")
        print("[PickupImportAgeDebug] normalizedMaxAge=\(debugAgeValue(maxAgeCell.normalizedValue))")
        print("[PickupImportAgeDebug] participantPreference=\(participantPreference.isEmpty ? "(empty)" : participantPreference)")
        print("[PickupImportAgeDebug] isFree=\(isFree.isEmpty ? "(empty)" : isFree)")
        print("[PickupImportAgeDebug] entryFee=\(entryFee.isEmpty ? "(empty)" : entryFee)")
        print("[PickupImportAgeDebug] maxPlayers=\(maxPlayers.isEmpty ? "(empty)" : maxPlayers)")
        print("[PickupImportAgeDebug] endTime=\(endTime.isEmpty ? "(empty)" : endTime)")
    }
#endif

    private static func duplicateRowKeys(_ rows: [PickupBulkImportRawRow]) -> Set<String> {
        var counts: [String: Int] = [:]
        for row in rows {
            let key = duplicateKey(for: row)
            counts[key, default: 0] += 1
        }
        return Set(counts.filter { $0.value > 1 }.map(\.key))
    }

    private static func duplicateKey(for row: PickupBulkImportRawRow) -> String {
        [
            row.value("title"),
            row.value("sport"),
            row.value("game_start_at"),
            row.value("address"),
            row.value("city"),
            row.value("state")
        ]
        .map { normalizeToken($0) }
        .joined(separator: "|")
    }

    private static func normalizeToken(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: #"\s+"#, with: "_", options: .regularExpression)
            .replacingOccurrences(of: "-", with: "_")
            .lowercased()
    }

    private static func parseDateTime(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let supabase = SupabaseTimestampParsing.parseTimestamptz(trimmed) {
            return supabase
        }
        if let serial = excelSerialNumber(from: trimmed), serial > 1 {
            return excelSerialDate(serial)
        }

        let formats = [
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd h:mm a",
            "MM/dd/yyyy HH:mm",
            "MM/dd/yyyy h:mm a",
            "M/d/yyyy HH:mm",
            "M/d/yyyy h:mm a",
            "M/d/yy h:mm a"
        ]
        return parseWithDateFormats(trimmed, formats: formats)
    }

    private static func parseEndTime(_ raw: String, start: Date?) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let full = parseDateTime(trimmed) {
            if let start, full < Calendar.current.startOfDay(for: start).addingTimeInterval(60) {
                return combineTime(full, withDateFrom: start)
            }
            return full
        }
        if let serial = excelSerialNumber(from: trimmed), serial > 0, serial < 1, let start {
            var combined = Calendar.current.startOfDay(for: start).addingTimeInterval(serial * 86_400)
            if combined <= start {
                combined = Calendar.current.date(byAdding: .day, value: 1, to: combined) ?? combined
            }
            return combined
        }
        guard let start else { return nil }
        let formats = ["HH:mm", "H:mm", "h:mm a", "ha", "h a"]
        guard let time = parseWithDateFormats(trimmed, formats: formats) else { return nil }
        var combined = combineTime(time, withDateFrom: start)
        if combined <= start {
            combined = Calendar.current.date(byAdding: .day, value: 1, to: combined) ?? combined
        }
        return combined
    }

    private static func parseWithDateFormats(_ raw: String, formats: [String]) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) {
                return date
            }
        }
        return nil
    }

    private static func excelSerialNumber(from raw: String) -> Double? {
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
        return Double(normalized)
    }

    private static func excelSerialDate(_ serial: Double) -> Date? {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = .current
        components.year = 1899
        components.month = 12
        components.day = 30
        guard let base = components.date else { return nil }
        return base.addingTimeInterval(serial * 86_400)
    }

    private static func combineTime(_ time: Date, withDateFrom date: Date) -> Date {
        let calendar = Calendar.current
        let dateParts = calendar.dateComponents([.year, .month, .day], from: date)
        let timeParts = calendar.dateComponents([.hour, .minute, .second], from: time)
        var combined = DateComponents()
        combined.calendar = calendar
        combined.timeZone = .current
        combined.year = dateParts.year
        combined.month = dateParts.month
        combined.day = dateParts.day
        combined.hour = timeParts.hour
        combined.minute = timeParts.minute
        combined.second = timeParts.second
        return calendar.date(from: combined) ?? date
    }

    private static func debugDateString(_ date: Date?) -> String {
        guard let date else { return "nil" }
        return PickupGameModels.encodeSupabaseTimestamptz(date)
    }
}
