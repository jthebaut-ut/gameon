import Combine
import PhotosUI
import SwiftUI

// MARK: - Add location (Phase C1)

/// Parent-owned draft so ``MapViewModel`` updates after photo upload do not drop ``@State`` inside the sheet.
final class AddLocationSheetFormState: ObservableObject {
    @Published var locationName = ""
    @Published var streetAddress = ""
    @Published var city = ""
    @Published var state = "UT"
    @Published var country = BusinessLocationCountryPolicy.defaultCountryCode
    @Published var zip = ""
    /// ITU dial country (ISO 3166-1 alpha-2), default US `+1`; paired with ``phoneLocal``.
    @Published var phoneDialISO = BusinessPhoneFields.defaultISO
    /// National portion only; combined for RPC as ``BusinessPhoneFields/combinedStorage(iso:local:)``.
    @Published var phoneLocal = ""
    @Published var website = ""
    @Published var description = ""
    @Published var proofNote = ""
    @Published var screenCount = 1
    @Published var servesFood = false
    @Published var hasWifi = false
    @Published var hasGarden = false
    @Published var hasProjector = false
    @Published var petFriendly = false
    @Published var familyFriendly = false
    @Published var parkingAvailable = false
    @Published var coverPhotoURL = ""
    @Published var menuPhotoURL = ""
    @Published var displayedCoverPhotoURL = ""
    @Published var displayedMenuPhotoURL = ""
    @Published var errorMessage = ""
    @Published var isSubmitting = false

    func reset(reason: String) {
#if DEBUG
        print("[AddLocationForm] reset reason=\(reason)")
#endif
        locationName = ""
        streetAddress = ""
        city = ""
        state = "UT"
        country = BusinessLocationCountryPolicy.defaultCountryCode
        zip = ""
        phoneDialISO = BusinessPhoneFields.defaultISO
        phoneLocal = ""
        website = ""
        description = ""
        proofNote = ""
        screenCount = 1
        servesFood = false
        hasWifi = false
        hasGarden = false
        hasProjector = false
        petFriendly = false
        familyFriendly = false
        parkingAvailable = false
        coverPhotoURL = ""
        menuPhotoURL = ""
        displayedCoverPhotoURL = ""
        displayedMenuPhotoURL = ""
        errorMessage = ""
        isSubmitting = false
    }
}

struct AddBusinessLocationRequestSheet: View {
    @ObservedObject var viewModel: MapViewModel
    @ObservedObject var form: AddLocationSheetFormState
    @Binding var submitBanner: String?
    @Binding var isPresented: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var selectedCoverPicker: PhotosPickerItem?
    @State private var selectedMenuPicker: PhotosPickerItem?

    /// Non-nil ``submitBanner`` only flags success; Settings parent maps status to user-facing copy.
    private static let successCopy = "submitted"

    /// Only URLs/uploads from this sheet — never fall back to managed-venue / signup state on ``MapViewModel``.
    private var coverPickerRemotePreview: String {
        form.displayedCoverPhotoURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var menuPickerRemotePreview: String {
        form.displayedMenuPhotoURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasMainVenuePhoto: Bool {
        !form.coverPhotoURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasMenuVenuePhoto: Bool {
        !form.menuPhotoURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var missingSubmitRequirements: [String] {
        var m: [String] = []
        if !viewModel.hasBusinessAccountForOwner() {
            m.append("Business account required")
        }
        if viewModel.currentBusinessIdForAddLocation() == nil {
            m.append("Could not resolve business for this request")
        }
        if form.locationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            m.append("Missing location name")
        }
        if form.streetAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            m.append("Missing address")
        }
        if form.city.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            m.append("Missing city")
        }
        if form.state.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            m.append("Missing state")
        }
        if form.zip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            m.append("Missing ZIP code")
        }
        let dialISO = form.phoneDialISO.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if BusinessPhoneFields.country(iso: dialISO) == nil {
            m.append("Missing country code")
        } else if BusinessPhoneFields.digitsOnly(form.phoneLocal).isEmpty {
            m.append("Missing phone number")
        } else if let phoneErr = BusinessPhoneFields.storageValidationError(iso: dialISO, local: form.phoneLocal) {
            m.append(phoneErr)
        }
        if form.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            m.append("Missing description")
        }
        if form.proofNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            m.append("Missing proof note")
        }
        if !hasMainVenuePhoto {
            m.append("Missing main venue photo")
        }
        return m
    }

    private var canSubmitLocationRequest: Bool {
        !form.isSubmitting && missingSubmitRequirements.isEmpty
    }

#if DEBUG
    private func logAddLocationFormState() {
        let bid = viewModel.currentBusinessIdForAddLocation()?.uuidString ?? "nil"
        print("[AddLocationForm] hasMainPhoto=\(hasMainVenuePhoto)")
        print("[AddLocationForm] hasMenuPhoto=\(hasMenuVenuePhoto)")
        print("[AddLocationForm] canSubmit=\(canSubmitLocationRequest)")
        print("[AddLocationForm] businessId=\(bid)")
    }
#endif

    var body: some View {
        let missing = missingSubmitRequirements
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FGSpacing.xl) {
                    FGCard {
                        FGSectionHeader(
                            "Location",
                            subtitle: "Submit a new FanGeo business location for review."
                        )

                        TextField("Location name", text: $form.locationName)
                            .textInputAutocapitalization(.words)
                            .fanGeoInputFieldStyle()
                        TextField("Street address", text: $form.streetAddress)
                            .fanGeoInputFieldStyle()
                        TextField("City", text: $form.city)
                            .textInputAutocapitalization(.words)
                            .fanGeoInputFieldStyle()

                        HStack(alignment: .center, spacing: FGSpacing.md) {
                            BusinessLocationUSStatePicker(title: "State", stateCode: $form.state)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            TextField("ZIP", text: $form.zip)
                                .textInputAutocapitalization(.never)
                                .frame(minWidth: 88, maxWidth: 120, alignment: .leading)
                        }
                        .fanGeoInputFieldStyle()

                        BusinessLocationCountryField(countryCode: $form.country)
                            .fanGeoInputFieldStyle()
                        BusinessPhoneNumberField(
                            dialISO: $form.phoneDialISO,
                            localNumber: $form.phoneLocal,
                            localPlaceholder: "(555) 123-4567"
                        )
                        TextField("Website (optional)", text: $form.website)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            .fanGeoInputFieldStyle()
                    }

                    FGCard {
                        AddLocationVenueFeaturesGrid(
                            screenCount: $form.screenCount,
                            servesFood: $form.servesFood,
                            hasWifi: $form.hasWifi,
                            hasGarden: $form.hasGarden,
                            hasProjector: $form.hasProjector,
                            petFriendly: $form.petFriendly,
                            parkingAvailable: $form.parkingAvailable,
                            familyFriendly: $form.familyFriendly,
                            maxScreenCount: 40
                        )
                    }

                    FGCard {
                        FGSectionHeader(
                            "Details",
                            subtitle: "Tell FanGeo what makes this location real and review-ready."
                        )

                        TextField("Description", text: $form.description, axis: .vertical)
                            .lineLimit(3...8)
                            .fanGeoInputFieldStyle()
                        TextField("Proof note (how you operate this location)", text: $form.proofNote, axis: .vertical)
                            .lineLimit(2...6)
                            .fanGeoInputFieldStyle()
                    }

                    FGCard {
                        FGSectionHeader(
                            "Photos",
                            subtitle: "Main venue photo is required. Menu photo is optional."
                        )

                        VenueOwnerListingPhotoPickerCard(
                            title: "Business Photo",
                            subtitle: "Main photo of your business",
                            pickerSelection: $selectedCoverPicker,
                            remotePreviewURL: coverPickerRemotePreview,
                            localPreviewData: nil,
                            usesFanGeoSheetChrome: true
                        )

                        VenueOwnerListingPhotoPickerCard(
                            title: "Menu Photo",
                            subtitle: "Food or drink menu photo",
                            pickerSelection: $selectedMenuPicker,
                            remotePreviewURL: menuPickerRemotePreview,
                            localPreviewData: nil,
                            usesFanGeoSheetChrome: true
                        )
                    }

                    FGCard {
                        FGSectionHeader(
                            "Required to submit",
                            subtitle: missing.isEmpty ? "All required fields are complete." : "Finish the items below before submitting."
                        )

                        if missing.isEmpty {
                            SettingsSheetStatusBanner(
                                title: "Ready to submit",
                                message: "All required fields are complete.",
                                tint: FGColor.accentGreen,
                                systemImage: "checkmark.circle.fill"
                            )
                        } else {
                            ForEach(missing, id: \.self) { line in
                                HStack(alignment: .top, spacing: FGSpacing.sm) {
                                    Image(systemName: "circle.fill")
                                        .font(.system(size: 6))
                                        .foregroundStyle(FGColor.accentYellow)
                                        .padding(.top, 6)
                                    Text(line)
                                        .font(FGTypography.caption)
                                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                                }
                            }
                        }
                    }

                    if !form.errorMessage.isEmpty {
                        SettingsSheetStatusBanner(
                            title: "Couldn’t submit location",
                            message: form.errorMessage,
                            tint: FGColor.dangerRed,
                            systemImage: "exclamationmark.triangle.fill"
                        )
                    }
                }
                .padding(.horizontal, FGSpacing.lg)
                .padding(.top, FGSpacing.lg)
                .padding(.bottom, SettingsScrollBottomLayout.sheetScrollComfortInset)
            }
            .scrollIndicators(.hidden)
            .fanGeoScreenBackground()
            .navigationTitle("Add location")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                form.errorMessage = ""
#if DEBUG
                logAddLocationFormState()
#endif
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        form.reset(reason: "cancel")
                        dismiss()
                        isPresented = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(form.isSubmitting ? "Submitting…" : "Submit location request") {
                        Task { await submit() }
                    }
                    .disabled(!canSubmitLocationRequest)
                }
            }
            .onChange(of: form.coverPhotoURL) { _, _ in
#if DEBUG
                logAddLocationFormState()
#endif
            }
            .onChange(of: form.menuPhotoURL) { _, _ in
#if DEBUG
                logAddLocationFormState()
#endif
            }
            .onChange(of: form.locationName) { _, _ in
#if DEBUG
                logAddLocationFormState()
#endif
            }
            .onChange(of: form.proofNote) { _, _ in
#if DEBUG
                logAddLocationFormState()
#endif
            }
            .onChange(of: selectedCoverPicker) { _, item in
                Task {
                    guard let item else { return }
#if DEBUG
                    print("[AddLocationForm] photo selected type=bar")
#endif
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let url = await viewModel.uploadVenuePhoto(data: data, fileName: "cover.jpg") {
                        await MainActor.run {
                            form.coverPhotoURL = url
                            form.displayedCoverPhotoURL = VenueOwnerPhotoPickerCopy.urlWithCacheBust(url)
                            selectedCoverPicker = nil
                            form.errorMessage = ""
#if DEBUG
                            print("[AddLocationForm] preserving form venueName=\(form.locationName)")
                            logAddLocationFormState()
#endif
                        }
                    } else {
                        await MainActor.run {
                            form.errorMessage = VenueOwnerPhotoPickerCopy.pickFailureUserHint()
                            selectedCoverPicker = nil
                        }
                    }
                }
            }
            .onChange(of: selectedMenuPicker) { _, item in
                Task {
                    guard let item else { return }
#if DEBUG
                    print("[AddLocationForm] photo selected type=menu")
#endif
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let url = await viewModel.uploadVenuePhoto(data: data, fileName: "menu.jpg") {
                        await MainActor.run {
                            form.menuPhotoURL = url
                            form.displayedMenuPhotoURL = VenueOwnerPhotoPickerCopy.urlWithCacheBust(url)
                            selectedMenuPicker = nil
                            form.errorMessage = ""
#if DEBUG
                            print("[AddLocationForm] preserving form venueName=\(form.locationName)")
                            logAddLocationFormState()
#endif
                        }
                    } else {
                        await MainActor.run {
                            form.errorMessage = VenueOwnerPhotoPickerCopy.pickFailureUserHint()
                            selectedMenuPicker = nil
                        }
                    }
                }
            }
        }
    }

    private func submit() async {
        await MainActor.run {
            form.errorMessage = ""
            form.isSubmitting = true
        }

        if viewModel.currentBusinessIdForAddLocation() == nil || !viewModel.hasBusinessAccountForOwner() {
#if DEBUG
            print("[AddLocation] blocked no business id")
#endif
            await MainActor.run {
                form.isSubmitting = false
                form.errorMessage = "Could not find a business account for this request."
            }
            return
        }

        let combinedPhone = BusinessPhoneFields.combinedStorage(
            iso: form.phoneDialISO,
            local: form.phoneLocal
        )

        let claim = AddLocationClaimForm(
            venueName: form.locationName,
            address: form.streetAddress,
            city: form.city,
            state: form.state,
            country: form.country,
            zip: form.zip,
            phone: combinedPhone,
            website: form.website,
            description: form.description,
            proofNote: form.proofNote,
            screenCount: form.screenCount,
            servesFood: form.servesFood,
            hasWifi: form.hasWifi,
            hasGarden: form.hasGarden,
            hasProjector: form.hasProjector,
            petFriendly: form.petFriendly,
            familyFriendly: form.familyFriendly,
            parkingAvailable: form.parkingAvailable,
            coverPhotoURL: form.coverPhotoURL,
            menuPhotoURL: form.menuPhotoURL
        )

        let err = await viewModel.submitAddLocationClaim(form: claim)

        await MainActor.run {
            form.isSubmitting = false
            if let err {
                form.errorMessage = err
            } else {
                submitBanner = Self.successCopy
                form.reset(reason: "success")
                dismiss()
                isPresented = false
            }
        }
    }
}
