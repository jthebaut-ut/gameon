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
                // Backend safety: required-field validation guard (UI should already enforce this).
                let trimmedName = ownerVenueName.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedAddress = ownerVenueAddress.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedCity = ownerVenueCity.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedState = ownerVenueState.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedZip = ownerVenueZipCode.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedPhone = ownerVenuePhone.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedDesc = ownerVenueDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedCover = venueCoverPhotoURL.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedMenu = venueMenuPhotoURL.trimmingCharacters(in: .whitespacesAndNewlines)

                guard !trimmedName.isEmpty,
                      !trimmedAddress.isEmpty,
                      !trimmedCity.isEmpty,
                      !trimmedState.isEmpty,
                      !trimmedZip.isEmpty,
                      !trimmedPhone.isEmpty,
                      !trimmedDesc.isEmpty else {
                    await MainActor.run {
                        venueAuthErrorMessage = "Complete all required fields before submitting."
                    }
                    return
                }

                guard !trimmedCover.isEmpty, !trimmedMenu.isEmpty else {
                    await MainActor.run {
                        venueAuthErrorMessage = "Please upload a venue photo and menu photo before submitting."
                    }
                    return
                }

                let claim = VenueClaimInsert(
                    owner_email: venueOwnerEmail,
                    venue_name: trimmedName,
                    venue_address: trimmedAddress,
                    venue_city: trimmedCity,
                    venue_state: trimmedState,
                    venue_zip_code: trimmedZip,
                    venue_phone: trimmedPhone,
                    venue_website: ownerVenueWebsite,
                    venue_description: trimmedDesc,
                    venue_features: ownerVenueFeatures,
                    screen_count: ownerVenueScreenCount,
                    serves_food: ownerVenueServesFood,
                    has_wifi: ownerVenueHasWifi,
                    has_garden: ownerVenueHasGarden,
                    has_projector: ownerVenueHasProjector,
                    pet_friendly: ownerVenuePetFriendly,
                    cover_photo_url: trimmedCover,
                    menu_photo_url: trimmedMenu,
                    proof_note: venueProofNote
                )

                struct InsertedClaimRow: Decodable {
                    let id: UUID
                    let created_at: String?
                    let approval_status: String?
                }

                let inserted: InsertedClaimRow = try await supabase
                    .from("venue_claims")
                    .insert(claim)
                    .select("id,created_at,approval_status")
                    .single()
                    .execute()
                    .value

                await MainActor.run {
                    venueClaimSubmitted = true
                    venueClaimStatus = "Pending Review"
                    venueClaimSubmittedDate = inserted.created_at ?? venueClaimSubmittedDate
                    venueAuthErrorMessage = ""
                }

#if DEBUG
                print("VenueClaim: inserted id=\(inserted.id.uuidString) status=\(inserted.approval_status ?? "unknown") created_at=\(inserted.created_at ?? "")")
#endif

                // Fire-and-forget admin email notification. Must not block claim submission UX.
                struct NotifyVenueClaimPayload: Encodable {
                    let claim_id: String
                    let owner_email: String
                    let venue_name: String
                    let venue_address: String
                    let venue_city: String
                    let venue_state: String
                    let venue_zip_code: String
                    let venue_phone: String
                    let venue_website: String
                    let venue_description: String
                    let venue_features: String
                    let screen_count: Int
                    let serves_food: Bool
                    let has_wifi: Bool
                    let has_garden: Bool
                    let has_projector: Bool
                    let pet_friendly: Bool
                    let proof_note: String
                    let cover_photo_url: String
                    let menu_photo_url: String
                    let photo_urls: [String]
                    let created_at: String
                    let approval_status: String
                }

                struct NotifyResponse: Decodable { let ok: Bool?; let error: String?; let detail: String? }

                let payload = NotifyVenueClaimPayload(
                    claim_id: inserted.id.uuidString,
                    owner_email: venueOwnerEmail,
                    venue_name: trimmedName,
                    venue_address: trimmedAddress,
                    venue_city: trimmedCity,
                    venue_state: trimmedState,
                    venue_zip_code: trimmedZip,
                    venue_phone: trimmedPhone,
                    venue_website: ownerVenueWebsite,
                    venue_description: trimmedDesc,
                    venue_features: ownerVenueFeatures,
                    screen_count: ownerVenueScreenCount,
                    serves_food: ownerVenueServesFood,
                    has_wifi: ownerVenueHasWifi,
                    has_garden: ownerVenueHasGarden,
                    has_projector: ownerVenueHasProjector,
                    pet_friendly: ownerVenuePetFriendly,
                    proof_note: venueProofNote,
                    cover_photo_url: trimmedCover,
                    menu_photo_url: trimmedMenu,
                    photo_urls: [trimmedCover, trimmedMenu].filter { !$0.isEmpty },
                    created_at: inserted.created_at ?? "",
                    approval_status: inserted.approval_status ?? "pending"
                )

                Task.detached { [supabase] in
#if DEBUG
                    print("VenueClaim: notify-venue-claim invoking (claim_id=\(payload.claim_id))")
#endif
                    do {
                        // Uses current session JWT automatically via Supabase client auth.
                        let response: NotifyResponse = try await supabase.functions.invoke(
                            "notify-venue-claim",
                            options: FunctionInvokeOptions(method: .post, body: payload)
                        )
#if DEBUG
                        print("VenueClaim: notify-venue-claim response ok=\(response.ok ?? false) error=\(response.error ?? "") detail=\(response.detail ?? "")")
#endif
                    } catch let error as FunctionsError {
#if DEBUG
                        if case let .httpError(status, data) = error {
                            let body = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
                            print("VenueClaim: notify-venue-claim httpError status=\(status) body=\(body)")
                        } else {
                            print("VenueClaim: notify-venue-claim functions error:", error)
                        }
#endif
                    } catch {
#if DEBUG
                        print("VenueClaim: notify-venue-claim unknown error:", error)
#endif
                    }
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
        Task { _ = await saveVenueGameListingAsync(
            gameTitle: gameTitle,
            sport: sport,
            gameDate: gameDate,
            gameStartTime: gameStartTime,
            soundOn: soundOn,
            audioType: audioType,
            teamFanbase: teamFanbase,
            atmosphere: atmosphere,
            crowdLevel: crowdLevel,
            liveOccupancy: liveOccupancy,
            seating: seating,
            numberOfTVs: numberOfTVs,
            drinkSpecial: drinkSpecial,
            coverCharge: coverCharge,
            reservationInfo: reservationInfo,
            socialCoordination: socialCoordination
        ) }
    }

    /// Same insert as ``saveVenueGameListing``; returns `nil` on success or a user-facing error string.
    func saveVenueGameListingAsync(
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
    ) async -> String? {
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
            return nil
        } catch {
            print("ERROR SAVING GAME LISTING:", error)
            return error.localizedDescription
        }
    }

    /// Updates only `event_title` for a venue-owned game (Manage Games title edit).
    func updateVenueGameEventTitle(id: UUID, newTitle: String) async -> String? {
        struct VenueEventTitlePatch: Encodable {
            let event_title: String
        }

        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Title can’t be empty." }

        do {
            let patch = VenueEventTitlePatch(event_title: trimmed)
            let _: [VenueEventRow] = try await supabase
                .from("venue_events")
                .update(patch)
                .eq("id", value: id.uuidString.lowercased())
                .select()
                .execute()
                .value

            return nil
        } catch {
            print("ERROR UPDATING VENUE GAME TITLE:", error)
            return error.localizedDescription
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

    /// Deletes the venue event row. Returns `nil` on success or an error message.
    func deleteVenueGame(_ game: VenueEventRow) async -> String? {
        guard let id = game.id else { return "This game can’t be removed (missing id)." }

        do {
            try await supabase
                .from("venue_events")
                .delete()
                .eq("id", value: id.uuidString.lowercased())
                .execute()

            print("VENUE GAME DELETED")
            return nil
        } catch {
            print("ERROR DELETING VENUE GAME:", error)
            return error.localizedDescription
        }
    }

    // MARK: - Venue owner analytics (interest counts for owned events)

    /// Fetches `venue_event_interests` rows for the given events and merges counts into `venueEventInterestCounts`
    /// without replacing counts for unrelated events (unlike ``loadVisibleVenueEventInterests()``).
    func loadInterestCountsForVenueEventIDs(_ eventIDs: [UUID]) async {
        guard !eventIDs.isEmpty else { return }

        let unique = Array(Set(eventIDs))
        let chunkSize = 90

        do {
            var counts: [UUID: Int] = [:]

            var index = 0
            while index < unique.count {
                let end = min(index + chunkSize, unique.count)
                let chunk = Array(unique[index..<end])
                index = end

                let rows: [VenueEventInterestRow] = try await supabase
                    .from("venue_event_interests")
                    .select("venue_event_id")
                    .in("venue_event_id", values: chunk)
                    .execute()
                    .value

                for row in rows {
                    guard let eventID = row.venue_event_id else { continue }
                    counts[eventID, default: 0] += 1
                }
            }

            await MainActor.run {
                for id in unique {
                    venueEventInterestCounts[id] = counts[id] ?? 0
                }
            }
        } catch {
            #if DEBUG
            print("ERROR LOADING INTEREST COUNTS FOR VENUE EVENT IDS:", error)
            #endif
        }
    }

    /// Engagement score for owner analytics: going/interested count + fan updates + all vibe taps.
    func venueOwnerEngagementScore(venueEventID: UUID) -> Int {
        let going = interestCountForVenueEvent(venueEventID)
        let comments = venueEventComments[venueEventID]?.count ?? 0
        let vibeTaps = venueEventVibeCounts[venueEventID]?.values.reduce(0, +) ?? 0
        return going + comments + vibeTaps
    }

    /// Trend label buckets for venue-owner analytics (distinct from map pin copy).
    func venueOwnerEngagementTrendLabel(score: Int) -> String {
        if score >= 40 {
            return "👑 Trending now"
        }
        if score >= 16 {
            return "🚀 Hot"
        }
        if score >= 6 {
            return "🔥 Active"
        }
        return "✨ Starting up"
    }
}
