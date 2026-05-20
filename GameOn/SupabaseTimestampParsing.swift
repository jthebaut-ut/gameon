import Foundation

/// Pure Supabase timestamptz parse/encode helpers safe to call from any isolation domain.
nonisolated enum SupabaseTimestampParsing {
    static func parseTimestamptz(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: trimmed) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: trimmed) { return date }

        if let normalized = postgresSpaceSeparatedISO(trimmed) {
            if let date = fractional.date(from: normalized) { return date }
            if let date = plain.date(from: normalized) { return date }
        }

        return posixDateFormatterParse(trimmed)
    }

    private static func postgresSpaceSeparatedISO(_ raw: String) -> String? {
        guard raw.count >= 19 else { return nil }
        let index = raw.index(raw.startIndex, offsetBy: 10)
        guard raw[index] == " " else { return nil }
        var normalized = raw
        normalized.replaceSubrange(index...index, with: "T")
        return normalized
    }

    private static func posixDateFormatterParse(_ raw: String) -> Date? {
        let formats = [
            "yyyy-MM-dd'T'HH:mm:ssXXXXX",
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSSZ",
            "yyyy-MM-dd"
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }

    static func encodeTimestamptz(_ date: Date) -> String {
        let encoder = ISO8601DateFormatter()
        encoder.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return encoder.string(from: date)
    }
}
