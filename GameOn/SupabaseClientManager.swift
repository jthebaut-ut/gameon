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
