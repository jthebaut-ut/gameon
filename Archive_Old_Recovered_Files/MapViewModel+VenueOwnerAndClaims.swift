import Foundation
import CoreLocation
import Supabase

// Venue-owner auth, `venue_claims` workflow, venue profile CRUD in `venues`, photo uploads, and related listings.

extension MapViewModel {

    // Creates a Supabase auth user in venue-owner mode (separate from end-user `isLoggedIn` state).
    func registerVenueOwner(email: String, password: String) async {
        do {
            _ = try await supabase.auth.signUp(
                email: email,
                password: password
            )

            await MainActor.run {
                venueOwnerEmail = email
                isVenueOwnerLoggedIn = true
                venueOwnerMode = true
                isLoggedIn = false
                currentUserEmail = ""
                venueClaimSubmitted = false
                venueIsApproved = false
                venueClaimStatus = "Not submitted"
                venueAuthErrorMessage = ""
            }

        } catch {
            await MainActor.run {
                let message = error.localizedDescription.lowercased()

                if message.contains("already registered") || message.contains("already exists") {
                    venueAuthErrorMessage = "This venue owner account already exists. Please use Login instead."
                } else if message.contains("email rate limit") {
                    venueAuthErrorMessage = "Email signup rate limit reached. Try again later or disable email confirmation during development."
                } else if message.contains("email signups are disabled") {
                    venueAuthErrorMessage = "Email signups are disabled in Supabase. Enable the Email provider."
                } else {
                    venueAuthErrorMessage = "Unable to create venue owner account."
                }
            }

            print("VENUE OWNER REGISTRATION ERROR:", error)
        }
    }

    // Signs in as venue owner and refreshes claim approval UI via `checkVenueApprovalStatus`.
    func loginVenueOwner(email: String, password: String) async {
        do {
            _ = try await supabase.auth.signIn(
                email: email,
                password: password
            )

            await MainActor.run {
                isVenueOwnerLoggedIn = true
                venueOwnerMode = true
                venueOwnerEmail = email
                isLoggedIn = false
                currentUserEmail = ""
                venueAuthErrorMessage = ""
                checkVenueApprovalStatus()
            }

        } catch {
            await MainActor.run {
                isVenueOwnerLoggedIn = false

                let message = error.localizedDescription.lowercased()

                if message.contains("invalid login credentials") {
                    venueAuthErrorMessage = "Venue owner account not found or incorrect password."
                } else {
                    venueAuthErrorMessage = "Unable to login venue owner."
                }
            }

            print("VENUE LOGIN ERROR:", error)
        }
    }

    // Loads the latest `venue_claims` row for `venueOwnerEmail` to drive pending/approved UI and prefilled venue fields.
    func checkVenueApprovalStatus() {
        Task {
            do {
                let claims: [VenueClaimRow] = try await supabase
                    .from("venue_claims")
                    .select()
                    .eq("owner_email", value: venueOwnerEmail)
                    .order("created_at", ascending: false)
                    .limit(1)
                    .execute()
                    .value
                
                await MainActor.run {
                    if let claim = claims.first {
                        venueClaimSubmitted = true
                        venueClaimStatus = claim.approval_status == "approved" ? "Approved" : "Pending Review"
                        venueIsApproved = claim.approval_status == "approved"
                        venueClaimSubmittedDate = claim.created_at ?? ""
                        
                        ownerVenueName = claim.venue_name ?? ""
                        ownerVenueAddress = claim.venue_address ?? ""
                        ownerVenuePhone = claim.venue_phone ?? ""
                        ownerVenueWebsite = claim.venue_website ?? ""
                        venueProofNote = claim.proof_note ?? ""
                    } else {
                        venueClaimSubmitted = false
                        venueClaimStatus = "Not Submitted"
                        venueIsApproved = false
                        venueClaimSubmittedDate = ""
                    }
                }
                
            } catch {
                print("ERROR CHECKING APPROVAL:", error)
            }
        }
    }

    // Inserts a new claim record from the owner onboarding form for admin review.
    func submitVenueClaim() {
        Task {
            do {
                let claim = VenueClaimInsert(
                    owner_email: venueOwnerEmail,
                    venue_name: ownerVenueName,
                    venue_address: ownerVenueAddress,
                    venue_city: ownerVenueCity,
                    venue_state: ownerVenueState,
                    venue_zip_code: ownerVenueZipCode,
                    venue_phone: ownerVenuePhone,
                    venue_website: ownerVenueWebsite,
                    venue_description: ownerVenueDescription,
                    venue_features: ownerVenueFeatures,
                    screen_count: ownerVenueScreenCount,
                    serves_food: ownerVenueServesFood,
                    has_wifi: ownerVenueHasWifi,
                    has_garden: ownerVenueHasGarden,
                    has_projector: ownerVenueHasProjector,
                    pet_friendly: ownerVenuePetFriendly,
                    cover_photo_url: venueCoverPhotoURL,
                    menu_photo_url: venueMenuPhotoURL,
                    proof_note: venueProofNote
                )

                try await supabase
                    .from("venue_claims")
                    .insert(claim)
                    .execute()

                await MainActor.run {
                    venueClaimSubmitted = true
                    venueClaimStatus = "Pending Review"
                }

            } catch {
                print("ERROR SAVING VENUE CLAIM:", error)
            }
        }
    }

    func approveVenueClaim(_ claim: VenueClaim) {
        guard let index = venueClaims.firstIndex(where: { $0.id == claim.id }) else { return }
        venueClaims[index].status = .approved
    }

    func rejectVenueClaim(_ claim: VenueClaim) {
        guard let index = venueClaims.firstIndex(where: { $0.id == claim.id }) else { return }
        venueClaims[index].status = .rejected
    }

    func loadRecentVenueEvents() {
        Task {
            do {

                let recentEvents: [VenueEventRow] = try await supabase
                    .from("venue_events")
                    .select()
                    .gte("event_date", value: tenDaysAgoString())
                    .execute()
                    .value

                print("RECENT EVENTS:", recentEvents)

            } catch {
                print("ERROR LOADING RECENT EVENTS:", error)
            }
        }
    }

    // Reads the `venues` row keyed by `venueOwnerEmail` for editing screens.
    func loadVenueProfile() async -> VenueProfileRow? {
        do {
            let rows: [VenueProfileRow] = try await supabase
                .from("venues")
                .select()
                .eq("owner_email", value: venueOwnerEmail)
                .limit(1)
                .execute()
                .value

            return rows.first

        } catch {
            print("ERROR LOADING VENUE PROFILE:", error)
            return nil
        }
    }

    // Geocodes the address, upserts into `venues` on `owner_email`, and reloads public venue data for the map.
    func saveVenueProfile(
        streetAddress: String,
        city: String,
        state: String,
        zipCode: String,
        screenCount: Int,
        servesFood: Bool,
        hasWifi: Bool,
        hasGarden: Bool,
        hasProjector: Bool,
        petFriendly: Bool
    ) async -> Bool {

        do {
            let fullAddress = [
                streetAddress,
                city,
                state,
                zipCode
            ]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")

            print("GEOCODING ADDRESS:", fullAddress)

            let coordinate = await geocodeAddress(fullAddress)

            let profile = VenueProfileInsert(
                owner_email: venueOwnerEmail,
                venue_name: ownerVenueName,
                address: streetAddress,
                city: city,
                state: state,
                zip_code: zipCode,
                phone: ownerVenuePhone,
                website: ownerVenueWebsite,
                description: ownerVenueDescription,
                features: ownerVenueFeatures,
                screen_count: screenCount,
                serves_food: servesFood,
                has_wifi: hasWifi,
                has_garden: hasGarden,
                has_projector: hasProjector,
                pet_friendly: petFriendly,
                latitude: coordinate?.latitude,
                longitude: coordinate?.longitude,
                cover_photo_url: venueCoverPhotoURL,
                menu_photo_url: venueMenuPhotoURL
            )

            try await supabase
                .from("venues")
                .upsert(profile, onConflict: "owner_email")
                .execute()

            print("VENUE PROFILE SAVED")
            await loadVenuesFromSupabase()
            return true

        } catch {

            print("ERROR SAVING VENUE PROFILE:", error)

            return false
        }
    }

    // Uploads a compressed JPEG under the owner’s email folder in `venue-photos` and returns its public URL.
    func uploadVenuePhoto(data: Data, fileName: String) async -> String? {
        do {
            let session = try? await supabase.auth.session
            print("CURRENT SUPABASE USER:", session?.user.email ?? "NO USER")
            print("VENUE OWNER EMAIL:", venueOwnerEmail)

            let safeEmail = venueOwnerEmail
                .lowercased()
                .replacingOccurrences(of: "@", with: "_")
                .replacingOccurrences(of: ".", with: "_")

            let path = "\(safeEmail)/\(fileName)"

            let uploadData = ImageCompression.jpegDataForUpload(from: data, preset: .venuePhoto)

            try await supabase.storage
                .from("venue-photos")
                .upload(
                    path,
                    data: uploadData,
                    options: FileOptions(
                        contentType: "image/jpeg",
                        upsert: true
                    )
                )

            let publicURL = try supabase.storage
                .from("venue-photos")
                .getPublicURL(path: path)

            return publicURL.absoluteString

        } catch {
            print("ERROR UPLOADING PHOTO:", error)
            return nil
        }
    }

    func saveVenueGameListing(
        gameTitle: String,
        sport: String,
        gameDate: Date,
        gameStartTime: Date,
        soundOn: Bool,
        audioType: VenueAudioType,
        teamFanbase: String,
        atmosphere: String,
        crowdLevel: String,
        liveOccupancy: String,
        seating: String,
        numberOfTVs: String,
        drinkSpecial: String,
        coverCharge: String,
        reservationInfo: String,
        socialCoordination: String
    ) {
        Task {
            do {
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyy-MM-dd"
                
                let timeFormatter = DateFormatter()
                timeFormatter.dateFormat = "h:mm a"
                
                let newGame = VenueEventInsert(
                    owner_email: venueOwnerEmail,
                    venue_name: ownerVenueName,
                    event_title: gameTitle,
                    sport: sport,
                    event_date: dateFormatter.string(from: gameDate),
                    event_time: timeFormatter.string(from: gameStartTime),
                    sound_on: soundOn,
                    audio_type: audioType.rawValue,
                    drink_special: drinkSpecial,
                    cover_charge: coverCharge,
                    expected_crowd: crowdLevel,
                    available_seating: seating,
                    reservations_available: !reservationInfo.isEmpty,
                    waitlist_available: !reservationInfo.isEmpty
                )
                
                try await supabase
                    .from("venue_events")
                    .insert(newGame)
                    .execute()
                
                print("GAME LISTING SAVED")
                
            } catch {
                print("ERROR SAVING GAME LISTING:", error)
            }
        }
    }

    func updateVenueGameListing(
        id: UUID,
        gameTitle: String,
        sport: String,
        gameDate: Date,
        gameStartTime: Date,
        soundOn: Bool,
        audioType: VenueAudioType,
        teamFanbase: String,
        atmosphere: String,
        crowdLevel: String,
        liveOccupancy: String,
        seating: String,
        numberOfTVs: String,
        drinkSpecial: String,
        coverCharge: String,
        reservationInfo: String,
        socialCoordination: String
    ) async {
        do {
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd"

            let timeFormatter = DateFormatter()
            timeFormatter.dateFormat = "h:mm a"

            struct VenueEventUpdate: Encodable {
                let event_title: String
                let sport: String
                let event_date: String
                let event_time: String
                let sound_on: Bool
                let audio_type: String
                let drink_special: String
                let cover_charge: String
                let expected_crowd: String
                let available_seating: String
                let reservations_available: Bool
                let waitlist_available: Bool
            }

            let updatedGame = VenueEventUpdate(
                event_title: gameTitle,
                sport: sport,
                event_date: dateFormatter.string(from: gameDate),
                event_time: timeFormatter.string(from: gameStartTime),
                sound_on: soundOn,
                audio_type: audioType.rawValue,
                drink_special: drinkSpecial,
                cover_charge: coverCharge,
                expected_crowd: crowdLevel,
                available_seating: liveOccupancy,
                reservations_available: !reservationInfo.isEmpty,
                waitlist_available: !socialCoordination.isEmpty
            )

            print("UPDATING GAME ID:", id)
            print("NEW TITLE:", gameTitle)

            let updatedRows: [VenueEventRow] = try await supabase
                .from("venue_events")
                .update(updatedGame)
                .eq("id", value: id.uuidString.lowercased())
                .select()
                .execute()
                .value

            print("UPDATED ROW COUNT:", updatedRows.count)
            print("UPDATED ROWS:", updatedRows)

        } catch {
            print("ERROR UPDATING VENUE GAME:", error)
        }
    }
    
    
    func loadMyVenueGames() async -> [VenueEventRow] {
        do {
            let rows: [VenueEventRow] = try await supabase
                .from("venue_events")
                .select()
                .eq("owner_email", value: venueOwnerEmail)
                .order("event_date", ascending: true)
                .execute()
                .value

            return rows
        } catch {
            print("ERROR LOADING MY VENUE GAMES:", error)
            return []
        }
    }

    func deleteVenueGame(_ game: VenueEventRow) async {
        guard let id = game.id else { return }

        do {
            let _ = try await supabase
                .from("venue_events")
                .delete()
                .eq("id", value: id.uuidString.lowercased())
                .execute()

            print("VENUE GAME DELETED")

        } catch {
            print("ERROR DELETING VENUE GAME:", error)
        }
    }
}
