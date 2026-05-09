import SwiftUI
import PhotosUI

struct VenueOwnerDashboardView: View {
    @ObservedObject var viewModel: MapViewModel
    
    @State private var selectedSection: VenueDashboardSection = .profile
    
    @State private var gameTitle = ""
    @State private var gameSpecial = ""
    @State private var soundOn = true
    @State private var coverCharge = ""
    @State private var seating = ""
    @State private var teamFanbase = ""
    @State private var socialCoordination = ""
    @State private var gameDate = Date()
    @State private var gameStartTime = Date()
    @State private var numberOfTVs = 1
    @State private var crowdLevel = "Moderate"
    @State private var liveOccupancy = "Open seats"
    @State private var reservationsAvailable = false
    @State private var waitlistAvailable = false
    @State private var showSpecialsFields = false
    @State private var hasFood = false
    @State private var hasWifi = false
    @State private var hasGarden = false
    @State private var hasProjector = false
    @State private var isPetFriendly = false
    @State private var totalScreens = 1
    @State private var profileSaveMessage = ""
    @State private var venueStreetAddress = ""
    @State private var venueCity = ""
    @State private var venueState = "UT"
    @State private var venueZipCode = ""
    @State private var selectedCoverPhoto: PhotosPickerItem?
    @State private var selectedMenuPhoto: PhotosPickerItem?
    
    
    
    
    enum VenueDashboardSection: String, CaseIterable {
        case profile = "Profile"
        case games = "Games"
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                
                header
                
                sectionPicker
                
                switch selectedSection {
                case .profile:
                    profileSection
                case .games:
                    gamesSection
                }
            }
            .padding()
        }
        .background(Color.black.opacity(0.94))
        .task {
            if let saved = await viewModel.loadVenueProfile() {

                viewModel.ownerVenueName = saved.venue_name ?? ""
                viewModel.ownerVenuePhone = saved.phone ?? ""
                viewModel.ownerVenueWebsite = saved.website ?? ""

                venueStreetAddress = saved.address ?? ""
                venueCity = saved.city ?? ""
                venueState = saved.state ?? "UT"
                venueZipCode = saved.zip_code ?? ""

                totalScreens = saved.screen_count ?? 1
                hasFood = saved.serves_food ?? false
                hasWifi = saved.has_wifi ?? false
                hasGarden = saved.has_garden ?? false
                hasProjector = saved.has_projector ?? false
                isPetFriendly = saved.pet_friendly ?? false
            }
        }
        
        .onChange(of: selectedCoverPhoto) { _, newItem in
            Task {
                if let data = try? await newItem?.loadTransferable(type: Data.self),
                   let url = await viewModel.uploadVenuePhoto(data: data, fileName: "cover.jpg") {
                    await MainActor.run {
                        viewModel.venueCoverPhotoURL = url
                        profileSaveMessage = "Cover photo uploaded. Tap Save Profile to save changes."
                    }
                }
            }
        }
        .onChange(of: selectedMenuPhoto) { _, newItem in
            Task {
                if let data = try? await newItem?.loadTransferable(type: Data.self),
                   let url = await viewModel.uploadVenuePhoto(data: data, fileName: "menu.jpg") {
                    await MainActor.run {
                        viewModel.venueMenuPhotoURL = url
                        profileSaveMessage = "Menu photo uploaded. Tap Save Profile to save changes."
                    }
                }
            }
        }
    }
    
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Venue Dashboard")
                .font(.largeTitle)
                .fontWeight(.bold)
                .foregroundStyle(.white)
            
            Text("Manage your bar profile, game schedule, specials, and game-day experience.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
        }
    }
    
    private var sectionPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(VenueDashboardSection.allCases, id: \.self) { section in
                    Button {
                        withAnimation(.spring()) {
                            selectedSection = section
                        }
                    } label: {
                        Text(section.rawValue)
                            .font(.caption)
                            .fontWeight(.bold)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(selectedSection == section ? Color.white : Color.white.opacity(0.15))
                            .foregroundStyle(selectedSection == section ? .black : .white)
                            .clipShape(Capsule())
                    }
                }
            }
        }
    }
    
    private var profileSection: some View {
        dashboardCard(title: "Venue Profile", subtitle: "Basic business information") {
            field("Bar / Pub / Restaurant Name", text: $viewModel.ownerVenueName)
            field("Street Address", text: $venueStreetAddress)
            field("City", text: $venueCity)

            Picker("State", selection: $venueState) {
                ForEach(usStates, id: \.self) { state in
                    Text(state).tag(state)
                }
            }
            .pickerStyle(.menu)
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.gray.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 16))

            field("ZIP Code", text: $venueZipCode)
            field("Phone", text: $viewModel.ownerVenuePhone)
            field("Website", text: $viewModel.ownerVenueWebsite)
            field("Short Description", text: $viewModel.ownerVenueDescription)
            field("Features: Big Screens, Patio, Sound On", text: $viewModel.ownerVenueFeatures)
            
            VStack(alignment: .leading, spacing: 14) {
                Text("Venue Features")
                    .font(.headline)
                    .fontWeight(.bold)

                Stepper("Number of screens: \(totalScreens)", value: $totalScreens, in: 1...100)

                Toggle("Serves food / drinks", isOn: $hasFood)
                Toggle("WiFi available", isOn: $hasWifi)
                Toggle("Garden / patio", isOn: $hasGarden)
                Toggle("Projector available", isOn: $hasProjector)
                Toggle("Pet friendly", isOn: $isPetFriendly)
            }
            .padding()
            .background(Color.gray.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 18))
            
            venuePhotoCard(
                title: "Bar Photo",
                subtitle: "Main photo of your venue",
                imageURL: viewModel.venueCoverPhotoURL
            )

            PhotosPicker(selection: $selectedCoverPhoto, matching: .images) {
                primaryButtonText(viewModel.venueCoverPhotoURL.isEmpty ? "Tap to upload photo" : "Tap to replace photo")
            }

            venuePhotoCard(
                title: "Menu Photo",
                subtitle: "Food or drink menu photo",
                imageURL: viewModel.venueMenuPhotoURL
            )

            PhotosPicker(selection: $selectedMenuPhoto, matching: .images) {
                primaryButtonText(viewModel.venueMenuPhotoURL.isEmpty ? "Tap to upload photo" : "Tap to replace photo")
            }

            PhotosPicker(
                selection: $selectedMenuPhoto,
                matching: .images
            ) {
                venuePhotoCard(
                    title: "Menu Photo",
                    subtitle: "Food or drink menu photo",
                    imageURL: viewModel.venueMenuPhotoURL
                )

                PhotosPicker(
                    selection: $selectedMenuPhoto,
                    matching: .images
                ) {
                    Text("Tap to upload photo")
                        .fontWeight(.bold)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.black)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
            }
            
            Button {
                profileSaveMessage = "Saving..."

                viewModel.ownerVenueAddress = "\(venueStreetAddress), \(venueCity), \(venueState) \(venueZipCode)"
                Task {
                    let success = await viewModel.saveVenueProfile(
                        streetAddress: venueStreetAddress,
                        city: venueCity,
                        state: venueState,
                        zipCode: venueZipCode,
                        screenCount: totalScreens,
                        servesFood: hasFood,
                        hasWifi: hasWifi,
                        hasGarden: hasGarden,
                        hasProjector: hasProjector,
                        petFriendly: isPetFriendly
                    )

                    await MainActor.run {
                        profileSaveMessage = success ? "Profile saved successfully" : "Unable to save profile"
                    }
                }
            } label: {
                primaryButtonText("Save Profile")
            }

            if !profileSaveMessage.isEmpty {
                Text(profileSaveMessage)
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }
    
    private let usStates = [
        "AL","AK","AZ","AR","CA","CO","CT","DE","FL","GA",
        "HI","ID","IL","IN","IA","KS","KY","LA","ME","MD",
        "MA","MI","MN","MS","MO","MT","NE","NV","NH","NJ",
        "NM","NY","NC","ND","OH","OK","OR","PA","RI","SC",
        "SD","TN","TX","UT","VT","VA","WA","WV","WI","WY"
    ]
    
    private var gamesSection: some View {
        dashboardCard(
            title: "Add Game Night",
            subtitle: "Tell fans what you are showing tonight. Keep it fast and simple."
        ) {
            field("Game title, example: France vs Brazil", text: $gameTitle)
            DatePicker("Game Date", selection: $gameDate, displayedComponents: .date)
                .fontWeight(.semibold)
                .padding()
                .background(Color.gray.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 16))

            DatePicker("Start Time", selection: $gameStartTime, displayedComponents: .hourAndMinute)
                .fontWeight(.semibold)
                .padding()
                .background(Color.gray.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 16))
            
            Picker("Sport", selection: $viewModel.ownerVenuePrimarySport) {
                ForEach(viewModel.sports.filter { $0 != "All" }, id: \.self) { sport in
                    Text(sport).tag(sport)
                }
            }
            .pickerStyle(.menu)
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.gray.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            
            Toggle("Audio / sound will be ON", isOn: $soundOn)
                .fontWeight(.semibold)
                .padding()
                .background(Color.gray.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 16))
            
            Stepper("TVs showing this game: \(numberOfTVs)", value: $numberOfTVs, in: 1...50)
                .fontWeight(.semibold)
                .padding()
                .background(Color.gray.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 16))
            
            field("Team fanbase, example: France fans, Brazil fans, Arsenal supporters", text: $teamFanbase)
            field("Cover charge, example: No cover, $10 after 7 PM", text: $coverCharge)
 
            Picker("Crowd Level", selection: $crowdLevel) {
                Text("Light").tag("Light")
                Text("Moderate").tag("Moderate")
                Text("Packed").tag("Packed")
            }
            .pickerStyle(.segmented)

            Picker("Live Occupancy", selection: $liveOccupancy) {
                Text("Open seats").tag("Open seats")
                Text("Filling up").tag("Filling up")
                Text("Standing room").tag("Standing room")
            }
            .pickerStyle(.segmented)

            

            Toggle("Reservations required", isOn: $reservationsAvailable)
                .fontWeight(.semibold)

            Toggle("Waitlist available", isOn: $waitlistAvailable)
                .fontWeight(.semibold)

            Button {
                withAnimation(.spring()) {
                    showSpecialsFields.toggle()
                }
            } label: {
                HStack {
                    Text(showSpecialsFields ? "Hide Specials" : "Add Drink/Food Specials")
                        .fontWeight(.bold)
                    Spacer()
                    Image(systemName: showSpecialsFields ? "chevron.up" : "chevron.down")
                }
                .padding()
                .background(Color.gray.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }

            if showSpecialsFields {
                field("Drink special", text: $gameSpecial)
                field("Cover charge", text: $coverCharge)
            }
            
            
            VStack(alignment: .leading, spacing: 12) {
                Text("Optional Game Photos")
                    .font(.headline)
                    .fontWeight(.bold)
                
                Text("These will later upload to Supabase Storage and attach only to this game.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                photoUploadPlaceholder(title: "Game Poster / Event Photo")
                photoUploadPlaceholder(title: "Game-Day Crowd Photo")
                photoUploadPlaceholder(title: "Drink Specials Photo")
            }
            
            Button {
                viewModel.saveVenueGameListing(
                    gameTitle: gameTitle,
                    sport: viewModel.ownerVenuePrimarySport,
                    gameDate: gameDate,
                    gameStartTime: gameStartTime,
                    soundOn: soundOn,
                    teamFanbase: teamFanbase,
                    atmosphere: "",
                    crowdLevel: crowdLevel,
                    liveOccupancy: liveOccupancy,
                    seating: seating,
                    numberOfTVs: "\(numberOfTVs)",
                    drinkSpecial: gameSpecial,
                    coverCharge: coverCharge,
                    reservationInfo: reservationsAvailable ? "Reservations available" : "",
                    socialCoordination: waitlistAvailable ? "Waitlist available" : ""
                )
            } label: {
                primaryButtonText("Save Game Listing")
            }
        }
    }
    
    private var specialsSection: some View {
        dashboardCard(title: "Game-Day Specials", subtitle: "Promotions users care about") {
            field("Drink specials", text: $viewModel.ownerVenueFeatures)
            field("Food special", text: $gameSpecial)
            field("Cover charge", text: $coverCharge)
            field("Reservations / waitlist info", text: $seating)
            
            Button {
                // Later: save specials to Supabase.
            } label: {
                primaryButtonText("Save Specials")
            }
        }
    }
    
    
    
    private func dashboardCard<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title2)
                .fontWeight(.bold)
            
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
            
            content()
        }
        .padding()
        .background(Color.white.opacity(0.96))
        .clipShape(RoundedRectangle(cornerRadius: 24))
    }
    
    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .padding()
            .background(Color.gray.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 16))
    }
    
    private func venuePhotoCard(
        title: String,
        subtitle: String,
        imageURL: String
    ) -> some View {
        
        VStack(alignment: .leading, spacing: 12) {
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .fontWeight(.bold)
                
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.gray.opacity(0.10))
                .frame(height: 140)
                .overlay {
                    if imageURL.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "photo")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                            
                            Text("No photo uploaded")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        AsyncImage(url: URL(string: imageURL)) { image in
                            image
                                .resizable()
                                .scaledToFill()
                        } placeholder: {
                            ProgressView()
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 18))
            
        }
    }
    
    private func photoUploadPlaceholder(title: String) -> some View {
        HStack {
            Image(systemName: "photo")
                .font(.title3)
                .foregroundStyle(.secondary)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.bold)
                
                Text("Optional")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Button {
                // Later: connect to PhotosPicker + Supabase Storage
            } label: {
                Text("Upload")
                    .font(.caption)
                    .fontWeight(.bold)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.black)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }
        }
        .padding()
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
    
    private func primaryButtonText(_ text: String) -> some View {
        Text(text)
            .fontWeight(.bold)
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.black)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

struct VenueFeatureIcon: View {
    let systemName: String
    let title: String
    let enabled: Bool

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Image(systemName: systemName)
                    .font(.title2)
                    .foregroundStyle(enabled ? .green : .gray)

                if !enabled {
                    Image(systemName: "slash.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .offset(x: 12, y: -12)
                }
            }

            Text(title)
                .font(.caption2)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)
        }
        .frame(width: 72)
    }
}
