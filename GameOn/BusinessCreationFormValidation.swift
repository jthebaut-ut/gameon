import Foundation

/// Validation for the Settings **business owner registration** + first-location form only.
/// Drives submit enabled/disabled and the single-line “next missing field” hint so they never disagree.
enum BusinessCreationFormValidation {

    /// First blocking issue in priority order. `nil` when all required fields and policies are satisfied (`isRegisterMode` must be true).
    static func businessCreationMissingRequirementMessage(
        isRegisterMode: Bool,
        venueOwnerEmail: String,
        venuePassword: String,
        policiesAccepted: Bool,
        businessName: String,
        locationName: String,
        streetAddress: String,
        city: String,
        state: String,
        zip: String,
        phoneDialISO: String,
        phoneLocal: String,
        description: String,
        proofNote: String,
        coverPhotoData: Data?
    ) -> String? {
        guard isRegisterMode else { return nil }

        let email = OwnerBusinessEmail.normalized(venueOwnerEmail)
        guard email.contains("@") else {
            return email.isEmpty ? "Business email missing" : "Enter a valid business email"
        }

        if venuePassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Password missing"
        }

        let biz = businessName.trimmingCharacters(in: .whitespacesAndNewlines)
        if biz.isEmpty { return "Business name missing" }

        let loc = locationName.trimmingCharacters(in: .whitespacesAndNewlines)
        if loc.isEmpty { return "Location name missing" }

        let street = streetAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if street.isEmpty { return "Address missing" }

        let cityT = city.trimmingCharacters(in: .whitespacesAndNewlines)
        if cityT.isEmpty { return "City missing" }

        let stateT = state.trimmingCharacters(in: .whitespacesAndNewlines)
        if stateT.isEmpty { return "State missing" }

        let zipT = zip.trimmingCharacters(in: .whitespacesAndNewlines)
        if zipT.isEmpty { return "ZIP code missing" }

        let phoneCombined = BusinessPhoneFields.combinedStorage(iso: phoneDialISO, local: phoneLocal)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if BusinessPhoneFields.storageValidationError(combined: phoneCombined) != nil {
            return BusinessPhoneFields.storageValidationError(iso: phoneDialISO, local: phoneLocal)
                ?? "Phone number missing"
        }

        let desc = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if desc.isEmpty { return "Description missing" }

        let proof = proofNote.trimmingCharacters(in: .whitespacesAndNewlines)
        if proof.isEmpty { return "Proof note missing" }

        let hasMain = coverPhotoData.map { !$0.isEmpty } ?? false
        if !hasMain { return "Business photo missing" }

        if !policiesAccepted {
            return "Agree to the Terms of Service, Privacy Policy, and Community Guidelines"
        }

        return nil
    }
}
