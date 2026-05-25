import CoreLocation
import Foundation

enum PickupImportRowStatus: String, Equatable {
    case valid
    case warning
    case failed

    var isImportable: Bool {
        self != .failed
    }
}

struct PickupImportPreparedRow: Identifiable, Equatable {
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
    let coordinate: CLLocationCoordinate2D?
    let warnings: [String]
    let errors: [String]

    var status: PickupImportRowStatus {
        if !errors.isEmpty { return .failed }
        if !warnings.isEmpty { return .warning }
        return .valid
    }

    var locationLine: String {
        [address, city, state].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    static func == (lhs: PickupImportPreparedRow, rhs: PickupImportPreparedRow) -> Bool {
        lhs.id == rhs.id
    }
}

struct PickupImportSummary: Equatable {
    let validCount: Int
    let warningCount: Int
    let failedCount: Int

    var importableCount: Int {
        validCount + warningCount
    }

    var totalCount: Int {
        validCount + warningCount + failedCount
    }
}

enum PickupImportValidation {
    static func summary(for rows: [PickupImportPreparedRow]) -> PickupImportSummary {
        PickupImportSummary(
            validCount: rows.filter { $0.status == .valid }.count,
            warningCount: rows.filter { $0.status == .warning }.count,
            failedCount: rows.filter { $0.status == .failed }.count
        )
    }

    @MainActor
    static func validate(rawRows: [PickupImportRawRow], viewModel: MapViewModel) async -> [PickupImportPreparedRow] {
#if DEBUG
        print("[PickupBulkValidation] started rows=\(rawRows.count)")
#endif
        let duplicateKeys = duplicateRowKeys(rawRows)
        var output: [PickupImportPreparedRow] = []
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
        raw: PickupImportRawRow,
        duplicateKeys: Set<String>,
        viewModel: MapViewModel
    ) async -> PickupImportPreparedRow {
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

        appendMissing("title", title, to: &errors)
        appendMissing("sport", sportRaw, to: &errors)
        appendMissing("skill_level", skillRaw, to: &errors)
        appendMissing("game_start_at", startRaw, to: &errors)
        appendMissing("address", address, to: &errors)
        appendMissing("city", city, to: &errors)
        appendMissing("state", state, to: &errors)
        appendMissing("players_needed", playersRaw, to: &errors)
        appendMissing("end_time", endRaw, to: &errors)

        let sport = canonicalSport(from: sportRaw)
        if sport == nil, !sportRaw.isEmpty {
            errors.append("Invalid sport name.")
        }

        let skillLevel = canonicalSkillLevel(from: skillRaw)
        if skillLevel == nil, !skillRaw.isEmpty {
            errors.append("Invalid skill level.")
        }

        let start = parseDateTime(startRaw)
        if start == nil, !startRaw.isEmpty {
            errors.append("Invalid game_start_at date.")
        } else if let start, start <= Date() {
            errors.append(VenueOwnerGameScheduleValidation.futureDateTimeMessage)
        }

        let end = parseEndTime(endRaw, start: start)
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
            warnings.append("max_players is blank; capacity will stay unset.")
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

        if description.isEmpty {
            warnings.append("description is blank.")
        }

        if duplicateKeys.contains(duplicateKey(for: raw)) {
            errors.append("Duplicate row in import file.")
        }

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
           let end,
           let coordinate {
            do {
                if try await viewModel.findOverlappingPickupGameAtLocation(
                    newStart: start,
                    newEnd: end,
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

        return PickupImportPreparedRow(
            rowNumber: raw.rowNumber,
            title: title,
            sport: sport ?? sportRaw,
            description: description.isEmpty ? nil : description,
            skillLevel: skillLevel ?? skillRaw,
            gameStartAt: start,
            endTime: end,
            address: address,
            city: city,
            state: state,
            playersNeeded: playersNeeded,
            maxPlayers: maxPlayers,
            coordinate: coordinate,
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
        for sport in AppSportCatalog.formPickerSportsOrdered {
            if sport.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
                || AppSportCatalog.displayLabel(forSportToken: sport).localizedCaseInsensitiveCompare(trimmed) == .orderedSame {
                return sport
            }
        }
        return nil
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

    private static func duplicateRowKeys(_ rows: [PickupImportRawRow]) -> Set<String> {
        var counts: [String: Int] = [:]
        for row in rows {
            let key = duplicateKey(for: row)
            counts[key, default: 0] += 1
        }
        return Set(counts.filter { $0.value > 1 }.map(\.key))
    }

    private static func duplicateKey(for row: PickupImportRawRow) -> String {
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
        if let serial = Double(trimmed), serial > 1 {
            return excelSerialDate(serial)
        }

        let formats = [
            "yyyy-MM-dd HH:mm",
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
        if let serial = Double(trimmed), serial > 0, serial < 1, let start {
            return Calendar.current.startOfDay(for: start).addingTimeInterval(serial * 86_400)
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

    private static func excelSerialDate(_ serial: Double) -> Date? {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
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
}
