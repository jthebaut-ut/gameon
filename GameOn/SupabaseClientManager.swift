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

/// Resolves the stored Supabase session for app restore paths. Expired sessions are signed out and treated as absent.
func supabaseResolvedAuthSession() async throws -> Session? {
    let session = try await supabase.auth.session
    if session.isExpired {
        try? await supabase.auth.signOut()
        return nil
    }
    return session
}
