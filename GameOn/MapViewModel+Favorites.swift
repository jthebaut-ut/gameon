import Foundation
import Supabase

extension MapViewModel {

    @MainActor
    private func applyLocalFavoriteState(bar: BarVenue, isFavorite: Bool) {
        if isFavorite {
            favoriteVenueIDs.insert(bar.id)
            if !followingTabSavedVenues.contains(where: { $0.id == bar.id }) {
                followingTabSavedVenues.insert(bar, at: 0)
            }
        } else {
            favoriteVenueIDs.remove(bar.id)
            followingTabSavedVenues.removeAll { $0.id == bar.id }
        }
    }

    func toggleFavorite(_ bar: BarVenue) {
        guard hasSupabaseSessionForFollowingTab else {
            print("LOGIN REQUIRED TO SAVE VENUE")
            return
        }

        Task {
            let wantFavorite = !favoriteVenueIDs.contains(bar.id)
            let ok = await setVenueFavorite(bar: bar, isFavorite: wantFavorite)
            if !ok {
                await MainActor.run {
                    showSocialActionToast("Couldn't update saved venue.")
                }
            }
        }
    }

    func loadFavoriteVenuesFromSupabase() async {
        do {
            let session = try await supabase.auth.session
            let email = session.user.email ?? ""

            guard !email.isEmpty else {
                favoriteVenueIDs = []
                clearFollowingTabCaches()
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
            await refreshFollowingTabDataGlobally()

        } catch {
            let message = error.localizedDescription.lowercased()

            if message.contains("duplicate key") || message.contains("23505") {
                await loadFavoriteVenuesFromSupabase()
                await refreshFollowingTabDataGlobally()
            } else {
                print("ERROR SAVING FAVORITE VENUE:", error)
            }
        }
    }

    func removeFavoriteVenueFromSupabase(_ bar: BarVenue) async {
        guard let email = await strictNormalizedSessionEmailForSocialTables() else { return }

        do {
            try await supabase
                .from("favorite_venues")
                .delete()
                .eq("user_email", value: email)
                .eq("venue_id", value: bar.id)
                .execute()

            await loadFavoriteVenuesFromSupabase()
            await refreshFollowingTabDataGlobally()

            print("FAVORITE VENUE REMOVED")

        } catch {
            print("ERROR REMOVING FAVORITE VENUE:", error)
        }
    }

    /// Optimistically updates ``favoriteVenueIDs``, writes to Supabase, and reverts locally on failure.
    @discardableResult
    func setVenueFavorite(bar: BarVenue, isFavorite: Bool) async -> Bool {
        guard hasSupabaseSessionForFollowingTab else { return false }
        guard !favoriteVenueWriteInFlightIDs.contains(bar.id) else { return true }

        let previous = favoriteVenueIDs
        let previousSavedVenues = followingTabSavedVenues
        await MainActor.run {
            favoriteVenueWriteInFlightIDs.insert(bar.id)
            applyLocalFavoriteState(bar: bar, isFavorite: isFavorite)
        }

        do {
            let email = await strictNormalizedSessionEmailForSocialTables()
            guard let email else { throw NSError(domain: "GameOn", code: 1) }

            if isFavorite {
                let favorite = FavoriteVenueInsert(
                    user_email: email,
                    venue_id: bar.id
                )

                try await supabase
                    .from("favorite_venues")
                    .insert(favorite)
                    .execute()
            } else {
                try await supabase
                    .from("favorite_venues")
                    .delete()
                    .eq("user_email", value: email)
                    .eq("venue_id", value: bar.id)
                    .execute()
            }
            await MainActor.run {
                favoriteVenueWriteInFlightIDs.remove(bar.id)
            }
            return true
        } catch {
            let message = error.localizedDescription.lowercased()

            if isFavorite, message.contains("duplicate key") || message.contains("23505") {
                await MainActor.run {
                    favoriteVenueWriteInFlightIDs.remove(bar.id)
                    applyLocalFavoriteState(bar: bar, isFavorite: true)
                }
                return true
            }

            await MainActor.run {
                favoriteVenueIDs = previous
                followingTabSavedVenues = previousSavedVenues
                favoriteVenueWriteInFlightIDs.remove(bar.id)
            }
            print("ERROR SETTING FAVORITE:", error)
            return false
        }
    }
}
