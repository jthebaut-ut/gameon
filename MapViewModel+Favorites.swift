import Foundation
import Supabase

extension MapViewModel {

    func toggleFavorite(_ bar: BarVenue) {
        guard isLoggedIn, !currentUserEmail.isEmpty else {
            print("LOGIN REQUIRED TO SAVE VENUE")
            return
        }

        Task {
            if favoriteVenueIDs.contains(bar.id) {
                await removeFavoriteVenueFromSupabase(bar)
            } else {
                await saveFavoriteVenueToSupabase(bar)
            }
        }
    }

    func loadFavoriteVenuesFromSupabase() async {
        do {
            let session = try await supabase.auth.session
            let email = session.user.email ?? ""

            guard !email.isEmpty else {
                favoriteVenueIDs = []
                return
            }

            print("LOADING FAVORITES AS:", email)

            let rows: [FavoriteVenueRow] = try await supabase
                .from("favorite_venues")
                .select()
                .eq("user_email", value: email)
                .execute()
                .value
           
          
            favoriteVenueIDs = Set(rows.compactMap { $0.venue_id })

      

        } catch {
            print("ERROR LOADING FAVORITE VENUES:", error)
        }
    }

    func saveFavoriteVenueToSupabase(_ bar: BarVenue) async {
        do {
            let session = try await supabase.auth.session
            let email = session.user.email ?? ""

            guard !email.isEmpty else {
                print("NO AUTH EMAIL FOR FAVORITE SAVE")
                return
            }

          

            let favorite = FavoriteVenueInsert(
                user_email: email,
                venue_id: bar.id
            )

            try await supabase
                .from("favorite_venues")
                .insert(favorite)
                .execute()

            await loadFavoriteVenuesFromSupabase()

        

        } catch {
            let message = error.localizedDescription.lowercased()

            if message.contains("duplicate key") || message.contains("23505") {
                await loadFavoriteVenuesFromSupabase()
            } else {
                print("ERROR SAVING FAVORITE VENUE:", error)
            }
        }
    }

    func removeFavoriteVenueFromSupabase(_ bar: BarVenue) async {
        guard !currentUserEmail.isEmpty else { return }

        do {
            try await supabase
                .from("favorite_venues")
                .delete()
                .eq("user_email", value: currentUserEmail)
                .eq("venue_id", value: bar.id)
                .execute()

            await loadFavoriteVenuesFromSupabase()

            print("FAVORITE VENUE REMOVED")

        } catch {
            print("ERROR REMOVING FAVORITE VENUE:", error)
        }
    }
}
