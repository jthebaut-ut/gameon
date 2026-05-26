import Foundation
import PostgREST
import Supabase

enum AnalyticsService {
    private struct TrackEventParams: Encodable {
        let p_event_type: String
        let p_entity_type: String?
        let p_entity_id: String?
        let p_metadata: [String: AnalyticsJSONValue]
    }

    static func track(
        event: String,
        entityType: String? = nil,
        entityId: String? = nil,
        metadata: [String: Any] = [:]
    ) {
        let normalizedEvent = cleaned(event, maxLength: 120)
        guard let normalizedEvent else { return }

        let params = TrackEventParams(
            p_event_type: normalizedEvent,
            p_entity_type: cleaned(entityType, maxLength: 80),
            p_entity_id: cleaned(entityId, maxLength: 160),
            p_metadata: sanitizedMetadata(metadata)
        )

        Task {
            do {
                _ = try await supabase
                    .rpc("track_event", params: params)
                    .execute()
            } catch {
#if DEBUG
                print("[AnalyticsService] track_event skipped event=\(normalizedEvent) error=\(error.localizedDescription)")
#endif
            }
        }
    }

    private static func cleaned(_ value: String?, maxLength: Int) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxLength))
    }

    private static func sanitizedMetadata(_ metadata: [String: Any]) -> [String: AnalyticsJSONValue] {
        metadata.reduce(into: [String: AnalyticsJSONValue]()) { result, pair in
            guard let key = cleaned(pair.key, maxLength: 80),
                  let value = AnalyticsJSONValue(pair.value) else {
                return
            }
            result[key] = value
        }
    }
}

private enum AnalyticsJSONValue: Encodable {
    case array([AnalyticsJSONValue])
    case bool(Bool)
    case double(Double)
    case int(Int)
    case object([String: AnalyticsJSONValue])
    case string(String)

    nonisolated init?(_ value: Any) {
        switch value {
        case let value as String:
            self = .string(String(value.prefix(500)))
        case let value as Bool:
            self = .bool(value)
        case let value as Int:
            self = .int(value)
        case let value as Double where value.isFinite:
            self = .double(value)
        case let value as Float where value.isFinite:
            self = .double(Double(value))
        case let value as UUID:
            self = .string(value.uuidString)
        case let value as Date:
            self = .string(Self.isoTimestamp(value))
        case let value as URL:
            self = .string(value.absoluteString)
        case let value as [Any]:
            self = .array(value.compactMap(AnalyticsJSONValue.init))
        case let value as [String: Any]:
            self = .object(Self.sanitizedObject(value))
        case _ as NSNull:
            return nil
        default:
            return nil
        }
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .array(let values):
            try container.encode(values)
        case .bool(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        }
    }

    nonisolated private static func sanitizedObject(_ object: [String: Any]) -> [String: AnalyticsJSONValue] {
        object.reduce(into: [String: AnalyticsJSONValue]()) { result, pair in
            let key = pair.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty,
                  let value = AnalyticsJSONValue(pair.value) else {
                return
            }
            result[String(key.prefix(80))] = value
        }
    }

    nonisolated private static func isoTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
