import Foundation
import Supabase

/// Shared Supabase client (Auth, PostgREST, Storage) used across ``MapViewModel`` extensions and upload helpers.
let supabaseProjectURL = URL(string: "https://srizbpfkigidsjxvpnkt.supabase.co")!
let supabasePublishableKey = "sb_publishable_Ijh60QL240MYjp59h80Eaw_BJCGwUlt"

let supabase = SupabaseClient(
    supabaseURL: supabaseProjectURL,
    supabaseKey: supabasePublishableKey,
    options: SupabaseClientOptions(
        auth: .init(emitLocalSessionAsInitialSession: true)
    )
)

enum SupabaseAuthSessionResolution {
    case active(Session)
    case missingSession
    case refreshFailed(Error)
}

/// Resolves the stored Supabase session for app restore paths without converting transient refresh failures into sign-out.
func supabaseResolvedAuthSessionResult() async -> SupabaseAuthSessionResolution {
    do {
        let session = try await supabase.auth.session
        guard session.isExpired else { return .active(session) }

        do {
            let refreshed = try await supabase.auth.refreshSession()
            return .active(refreshed)
        } catch {
            return .refreshFailed(error)
        }
    } catch {
        return supabaseAuthErrorLooksLikeMissingSession(error) ? .missingSession : .refreshFailed(error)
    }
}

/// Back-compat wrapper for older call sites: refresh failures still throw, while a real missing session is nil.
func supabaseResolvedAuthSession() async throws -> Session? {
    switch await supabaseResolvedAuthSessionResult() {
    case .active(let session):
        return session
    case .missingSession:
        return nil
    case .refreshFailed(let error):
        throw error
    }
}

enum FanGeoAnalyticsService {
    struct EventPayload: Encodable {
        let user_id: UUID?
        let event_name: String
        let entity_type: String?
        let entity_id: UUID?
        let city: String?
        let region: String?
        let country: String?
        let sport: String?
        let metadata: [String: String]
    }

    struct LastActivePayload: Encodable {
        let last_active_at: String
    }

    static func recordAppOpen() {
        record(eventName: "app_open", updateLastActive: true)
    }

    static func recordDiscoverView(mode: String? = nil, sport: String? = nil) {
        var metadata: [String: String] = [:]
        if let mode, !mode.isEmpty {
            metadata["mode"] = mode
        }
        record(eventName: "discover_view", sport: sport, metadata: metadata, updateLastActive: true)
    }

    static func recordVenueView(venueId: UUID?, city: String?, region: String?, country: String?, sport: String?) {
        record(
            eventName: "venue_view",
            entityType: "venue",
            entityId: venueId,
            city: city,
            region: region,
            country: country,
            sport: sport,
            updateLastActive: true
        )
    }

    static func recordGameCreated(gameId: UUID?, city: String?, region: String?, country: String?, sport: String?) {
        record(
            eventName: "game_created",
            entityType: "pickup_game",
            entityId: gameId,
            city: city,
            region: region,
            country: country,
            sport: sport,
            updateLastActive: true
        )
    }

    static func recordGameJoined(gameId: UUID?, sport: String? = nil) {
        record(
            eventName: "game_joined",
            entityType: "game",
            entityId: gameId,
            sport: sport,
            updateLastActive: true
        )
    }

    static func recordCommentPosted(venueEventId: UUID?) {
        record(
            eventName: "comment_posted",
            entityType: "venue_event",
            entityId: venueEventId,
            updateLastActive: true
        )
    }

    static func recordDMSent(conversationId: UUID?) {
        record(
            eventName: "dm_sent",
            entityType: "direct_conversation",
            entityId: conversationId,
            updateLastActive: true
        )
    }

    static func touchLastActive() {
        record(eventName: "activity_touch", updateLastActive: true)
    }

    static func record(
        eventName: String,
        entityType: String? = nil,
        entityId: UUID? = nil,
        city: String? = nil,
        region: String? = nil,
        country: String? = nil,
        sport: String? = nil,
        metadata: [String: String] = [:],
        updateLastActive: Bool = true
    ) {
        let normalizedName = eventName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { return }

        Task(priority: .background) {
            do {
                let session = try await supabase.auth.session
                let userId = session.user.id
                let now = isoTimestamp(Date())

                if updateLastActive {
                    _ = try? await supabase
                        .from("user_profiles")
                        .update(LastActivePayload(last_active_at: now))
                        .eq("id", value: userId.uuidString)
                        .execute()
                }

                let payload = EventPayload(
                    user_id: userId,
                    event_name: normalizedName,
                    entity_type: cleaned(entityType),
                    entity_id: entityId,
                    city: cleaned(city),
                    region: cleaned(region),
                    country: cleaned(country),
                    sport: cleaned(sport),
                    metadata: metadata.filter { !$0.key.isEmpty && !$0.value.isEmpty }
                )

                try await supabase
                    .from("analytics_events")
                    .insert(payload)
                    .execute()
            } catch {
#if DEBUG
                print("[Analytics] event=\(normalizedName) skipped error=\(error.localizedDescription)")
#endif
            }
        }
    }

    private static func cleaned(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : String(trimmed.prefix(120))
    }

    private static func isoTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private func supabaseAuthErrorLooksLikeMissingSession(_ error: Error) -> Bool {
    let text = "\(error.localizedDescription) \(String(describing: error))".lowercased()
    return text.contains("session") && (
        text.contains("missing")
            || text.contains("not found")
            || text.contains("not exist")
            || text.contains("no current")
            || text.contains("not authenticated")
            || text.contains("unauthenticated")
    )
}
