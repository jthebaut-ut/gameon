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
                        let status = (claim.approval_status ?? "").lowercased()
                        if status == "approved" {
                            venueClaimStatus = "Approved"
                            venueIsApproved = true
                        } else if status == "rejected" {
                            venueClaimStatus = "Rejected"
                            venueIsApproved = false
                        } else {
                            venueClaimStatus = "Pending Review"
                            venueIsApproved = false
                        }
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
                func trimmed(_ s: String) -> String {
                    s.trimmingCharacters(in: .whitespacesAndNewlines)
                }

                // Backend safety: validate required fields before inserting or emailing.
                // NOTE: UI also disables submission until valid, but this prevents bypass.
                let missingRequiredPhotos = trimmed(venueCoverPhotoURL).isEmpty || trimmed(venueMenuPhotoURL).isEmpty
                let missingRequiredFields =
                    trimmed(ownerVenueName).isEmpty
                        || trimmed(ownerVenueAddress).isEmpty
                        || trimmed(ownerVenueCity).isEmpty
                        || trimmed(ownerVenueState).isEmpty
                        || trimmed(ownerVenueZipCode).isEmpty
                        || trimmed(ownerVenuePhone).isEmpty
                        || trimmed(ownerVenueDescription).isEmpty
                        || trimmed(ownerVenueFeatures).isEmpty

                if missingRequiredPhotos {
                    await MainActor.run {
                        venueAuthErrorMessage = "Please upload a venue photo and menu photo before submitting."
                    }
#if DEBUG
                    print("VenueClaim: blocked submit (missing required photos)")
#endif
                    return
                }
                if missingRequiredFields {
                    await MainActor.run {
                        venueAuthErrorMessage = "Please complete all required venue information before submitting."
                    }
#if DEBUG
                    print("VenueClaim: blocked submit (missing required fields)")
#endif
                    return
                }

                struct NotifyVenueClaimPayload: Encodable {
                    let claim_id: String
                    let owner_email: String
                    let venue_name: String
                    let created_at: String
                    let approval_status: String

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

                    let cover_photo_url: String
                    let menu_photo_url: String
                    let venue_crowd_photo_url: String
                    let venue_tv_wall_photo_url: String
                    let venue_specials_photo_url: String
                    let proof_note: String

                    let photo_urls: [String]
                }

                func isoNow() -> String {
                    let f = ISO8601DateFormatter()
                    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    return f.string(from: Date())
                }

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

                struct InsertedClaimRow: Decodable {
                    let id: String?
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
                }

                // Fire-and-forget admin email notification (does NOT block claim submission).
                // TODO: If Edge Function/RLS evolves, consider moving this to a DB trigger so emails cannot be bypassed.
                struct NotifyVenueClaimResponse: Decodable { let ok: Bool? }
                let claimIdForEmail = (inserted.id ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if claimIdForEmail.isEmpty {
#if DEBUG
                    print("VenueClaim: missing inserted claim id; skipping notify-venue-claim")
#endif
                    return
                }
                let payload = NotifyVenueClaimPayload(
                    claim_id: claimIdForEmail,
                    owner_email: venueOwnerEmail,
                    venue_name: ownerVenueName,
                    created_at: inserted.created_at ?? isoNow(),
                    approval_status: (inserted.approval_status ?? "pending"),

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
                    venue_crowd_photo_url: venueCrowdPhotoURL,
                    venue_tv_wall_photo_url: venueTVWallPhotoURL,
                    venue_specials_photo_url: venueSpecialsPhotoURL,
                    proof_note: venueProofNote,

                    photo_urls: [
                        venueCoverPhotoURL,
                        venueMenuPhotoURL,
                        venueCrowdPhotoURL,
                        venueTVWallPhotoURL,
                        venueSpecialsPhotoURL,
                    ]
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                )

                Task.detached {
                    do {
                        let _: NotifyVenueClaimResponse = try await supabase.functions.invoke(
                            "notify-venue-claim",
                            options: FunctionInvokeOptions(method: .post, body: payload)
                        )
                    } catch {
#if DEBUG
                        print("VenueClaim: notify-venue-claim failed (non-blocking):", error)
#endif
                    }
                }

            } catch {
                print("ERROR SAVING VENUE CLAIM:", error)
            }
        }
    }

    /// Admin action: persists `approval_status` to Supabase. Optimistic UI with rollback on failure.
    func approveVenueClaim(_ claim: VenueClaim) {
        persistVenueClaimDecision(claimId: claim.id, decision: .approved)
    }

    /// Admin action: persists `approval_status` to Supabase. Optimistic UI with rollback on failure.
    func rejectVenueClaim(_ claim: VenueClaim) {
        persistVenueClaimDecision(claimId: claim.id, decision: .rejected)
    }

    private enum VenueClaimDecision: String {
        case approved = "approved"
        case rejected = "rejected"
    }

    private func persistVenueClaimDecision(claimId: UUID, decision: VenueClaimDecision) {
        guard let index = venueClaims.firstIndex(where: { $0.id == claimId }) else { return }
        let previous = venueClaims[index].status

        // Optimistic update.
        venueClaims[index].status = (decision == .approved) ? .approved : .rejected

        Task {
            do {
                struct Update: Encodable { let approval_status: String }
                _ = try await supabase
                    .from("venue_claims")
                    .update(Update(approval_status: decision.rawValue))
                    .eq("id", value: claimId.uuidString)
                    .execute()

                // Refresh admin list + public venues (in case newly approved venues should appear).
                await loadVenueClaimsForAdmin()
                await loadVenuesFromSupabase()
            } catch {
                // Roll back optimistic state.
                await MainActor.run {
                    if let i = venueClaims.firstIndex(where: { $0.id == claimId }) {
                        venueClaims[i].status = previous
                    }
                    authErrorMessage = "Failed to update claim status. \(error.localizedDescription)"
                }
                print("ERROR UPDATING VENUE CLAIM STATUS:", error)
            }
        }
    }

    /// Loads recent venue claims for Admin review UI.
    func loadVenueClaimsForAdmin(limit: Int = 100) async {
        do {
            let rows: [VenueClaimRow] = try await supabase
                .from("venue_claims")
                .select()
                .order("created_at", ascending: false)
                .limit(limit)
                .execute()
                .value

            let mapped: [VenueClaim] = rows.compactMap { row in
                guard let idStr = row.id, let id = UUID(uuidString: idStr) else { return nil }
                let statusRaw = (row.approval_status ?? "").lowercased()
                let status: VenueClaimStatus
                switch statusRaw {
                case "approved": status = .approved
                case "rejected": status = .rejected
                default: status = .pending
                }
                return VenueClaim(
                    id: id,
                    venueName: row.venue_name ?? "Venue",
                    address: row.venue_address ?? "",
                    businessEmail: row.owner_email ?? "",
                    phone: row.venue_phone ?? "",
                    website: row.venue_website ?? "",
                    proofNote: row.proof_note ?? "",
                    primarySport: "",
                    status: status
                )
            }

            await MainActor.run {
                venueClaims = mapped
            }
        } catch {
            await MainActor.run {
                authErrorMessage = "Failed to load venue claims. \(error.localizedDescription)"
            }
            print("ERROR LOADING VENUE CLAIMS:", error)
        }
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

            // Photo-change review workflow:
            // If the venue is already approved and the owner uploads a new bar/menu photo,
            // do NOT overwrite the public photo immediately. Store pending URLs instead and notify admin.
            let existingProfile = await loadVenueProfile()
            let existingCover = existingProfile?.cover_photo_url ?? ""
            let existingMenu = existingProfile?.menu_photo_url ?? ""
            let submittedCover = venueCoverPhotoURL
            let submittedMenu = venueMenuPhotoURL

            let coverChanged = venueIsApproved
                && !submittedCover.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && submittedCover != existingCover
            let menuChanged = venueIsApproved
                && !submittedMenu.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && submittedMenu != existingMenu

            let publicCoverForUpsert = (venueIsApproved && coverChanged) ? existingCover : submittedCover
            let publicMenuForUpsert = (venueIsApproved && menuChanged) ? existingMenu : submittedMenu

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
                cover_photo_url: publicCoverForUpsert,
                menu_photo_url: publicMenuForUpsert
            )

            try await supabase
                .from("venues")
                .upsert(profile, onConflict: "owner_email")
                .execute()

            if venueIsApproved && (coverChanged || menuChanged) {
                struct Update: Encodable {
                    let pending_cover_photo_url: String?
                    let pending_menu_photo_url: String?
                    let photo_review_status: String
                    let photo_review_created_at: String
                }
                let f = ISO8601DateFormatter()
                f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let nowIso = f.string(from: Date())

                try await supabase
                    .from("venues")
                    .update(
                        Update(
                            pending_cover_photo_url: coverChanged ? submittedCover : nil,
                            pending_menu_photo_url: menuChanged ? submittedMenu : nil,
                            photo_review_status: "pending",
                            photo_review_created_at: nowIso
                        )
                    )
                    .eq("owner_email", value: venueOwnerEmail)
                    .execute()

                // Fire-and-forget admin email notification for photo review.
                struct NotifyResponse: Decodable { let ok: Bool? }
                struct NotifyPayload: Encodable {
                    let venue_id: String
                    let venue_name: String
                    let owner_email: String
                    let created_at: String
                    let photo_review_status: String
                    let old_cover_photo_url: String
                    let old_menu_photo_url: String
                    let pending_cover_photo_url: String
                    let pending_menu_photo_url: String
                    let photo_urls: [String]
                }

                let venueId = existingProfile?.id?.uuidString ?? ""
                if !venueId.isEmpty {
                    let payload = NotifyPayload(
                        venue_id: venueId,
                        venue_name: ownerVenueName,
                        owner_email: venueOwnerEmail,
                        created_at: nowIso,
                        photo_review_status: "pending",
                        old_cover_photo_url: existingCover,
                        old_menu_photo_url: existingMenu,
                        pending_cover_photo_url: coverChanged ? submittedCover : "",
                        pending_menu_photo_url: menuChanged ? submittedMenu : "",
                        photo_urls: [submittedCover, submittedMenu]
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                    )
                    Task.detached {
                        do {
                            let _: NotifyResponse = try await supabase.functions.invoke(
                                "notify-venue-photo-change",
                                options: FunctionInvokeOptions(method: .post, body: payload)
                            )
                        } catch {
#if DEBUG
                            print("VenuePhotoChange: notify failed (non-blocking):", error)
#endif
                        }
                    }
                }

                // Keep the approved (public) photos in local state; pending photos are stored server-side.
                await MainActor.run {
                    venueCoverPhotoURL = existingCover
                    venueMenuPhotoURL = existingMenu
                }
            }

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

            // Use unique object keys so approved public photos are not overwritten when replacements are pending review.
            let base = fileName
                .replacingOccurrences(of: ".jpg", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: ".jpeg", with: "", options: .caseInsensitive)
            let path = "\(safeEmail)/\(base)-\(UUID().uuidString.lowercased()).jpg"

            // Compress off-main-thread to keep UI responsive.
            let uploadData = await Task.detached {
                ImageCompression.jpegDataForUpload(from: data, preset: .venuePhoto)
            }.value

            try await supabase.storage
                .from("venue-photos")
                .upload(
                    path,
                    data: uploadData,
                    options: FileOptions(
                        contentType: "image/jpeg",
                        upsert: false
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

    /// Attempts to delete a previously uploaded venue photo object from Storage.
    /// - Important: For approved venues with pending replacements, do not delete the old public photo until moderation approves.
    func deleteVenuePhotoIfPossible(previousPhotoURL: String) async {
        let trimmed = previousPhotoURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let objectPath = Self.storageObjectPathFromPublicURL(trimmed, bucket: "venue-photos") else { return }
        do {
            _ = try await supabase.storage
                .from("venue-photos")
                .remove(paths: [objectPath])
        } catch {
#if DEBUG
            print("VenuePhotoDelete: failed (non-fatal):", error)
#endif
        }
    }

    private static func storageObjectPathFromPublicURL(_ urlString: String, bucket: String) -> String? {
        guard let url = URL(string: urlString) else { return nil }
        let path = url.path
        let needle = "/object/public/\(bucket)/"
        guard let range = path.range(of: needle) else { return nil }
        let object = String(path[range.upperBound...])
        return object.isEmpty ? nil : object
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
