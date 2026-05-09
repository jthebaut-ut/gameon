import Foundation
import Supabase

/// Shared Supabase client (Auth, PostgREST, Storage) used across ``MapViewModel`` extensions and upload helpers.
let supabase = SupabaseClient(
    supabaseURL: URL(string: "https://srizbpfkigidsjxvpnkt.supabase.co")!,
    supabaseKey: "sb_publishable_Ijh60QL240MYjp59h80Eaw_BJCGwUlt"
)
