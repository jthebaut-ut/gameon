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
        return plain.date(from: trimmed)
    }

    static func encodeTimestamptz(_ date: Date) -> String {
        let encoder = ISO8601DateFormatter()
        encoder.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return encoder.string(from: date)
    }
}
