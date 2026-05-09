import SwiftUI

struct VenueDetailView: View {
    let bar: BarVenue
    let selectedEvent: SportsEvent?
    let isFavorite: Bool
    let goingCount: Int
    let iconForSport: (String) -> String
    let onDirections: () -> Void
    let onCall: () -> Void
    let onFavorite: () -> Void
    let experience: VenueExperience?
    var coverPhotoURL: String? = nil
    var menuPhotoURL: String? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                
                RoundedRectangle(cornerRadius: 28)
                    .fill(
                        LinearGradient(
                            colors: [Color.black.opacity(0.9), Color.gray.opacity(0.55)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(height: 190)
                    .overlay {
                        VStack(spacing: 10) {
                            Image(systemName: iconForSport(bar.primarySport))
                                .font(.system(size: 48, weight: .bold))
                                .foregroundStyle(.white)
                            
                            Text("Confirmed Sports Venue")
                                .font(.headline)
                                .foregroundStyle(.white)
                            
                            Text(bar.primarySport)
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.75))
                        }
                    }
                
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(bar.name)
                            .font(.largeTitle)
                            .fontWeight(.bold)
                        
                        Text(bar.address)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                    
                    Button(action: onFavorite) {
                        Image(systemName: isFavorite ? "heart.fill" : "heart")
                            .font(.title2)
                            .foregroundStyle(isFavorite ? .red : .secondary)
                    }
                }
                
                HStack {
                    infoBox(title: bar.distance, subtitle: "Away", icon: "location.fill")
                    infoBox(title: String(format: "%.1f", bar.rating), subtitle: "Rating", icon: "star.fill")
                    infoBox(title: bar.primarySport, subtitle: "Sport", icon: iconForSport(bar.primarySport))
                }
                if let experience {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Game Day Experience")
                            .font(.title2)
                            .fontWeight(.bold)

                        experienceRow("Atmosphere", experience.atmosphere, "sparkles")
                        experienceRow("Crowd", experience.crowdLevel, "person.3.fill")
                        experienceRow("Fanbase", experience.teamFanbases.joined(separator: " • "), "flag.fill")
                        experienceRow("Audio", experience.hasAudio ? "Sound will be on" : "No confirmed audio", experience.hasAudio ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        experienceRow("Drink Specials", experience.drinkSpecials, "mug.fill")
                        experienceRow("Seating", experience.availableSeating, "chair.lounge.fill")
                        experienceRow("Cover", experience.coverCharge, "dollarsign.circle.fill")
                        experienceRow("Reservations", experience.reservationsAvailable ? "Reservations available" : "No reservations", "calendar.badge.clock")
                        experienceRow("Waitlist", experience.waitlistAvailable ? "Waitlist available" : "No waitlist", "list.bullet.clipboard")
                        experienceRow("Social", experience.socialCoordination, "person.2.wave.2.fill")
                    }
                }
                
                
                if let selectedEvent, goingCount > 0 {
                    HStack {
                        Image(systemName: "person.3.fill")
                            .foregroundStyle(.green)
                        
                        Text("\(goingCount) people interested / going for \(selectedEvent.title)")
                            .fontWeight(.bold)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                
                HStack {
                    actionButton(title: "Directions", icon: "map.fill", color: .black, action: onDirections)
                    actionButton(title: "Call", icon: "phone.fill", color: .blue, action: onCall)
                    actionButton(title: isFavorite ? "Saved" : "Save", icon: isFavorite ? "heart.fill" : "heart", color: .red, action: onFavorite)
                }
                
                VStack(alignment: .leading, spacing: 10) {
                    Text("Games Showing")
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    ForEach(bar.games, id: \.self) { game in
                        HStack {
                            Image(systemName: "tv.fill")
                            
                            Text(game)
                                .fontWeight(.medium)
                            
                            Spacer()
                            
                            Text(selectedEvent?.title == game ? "Selected" : "Confirmed")
                                .font(.caption)
                                .fontWeight(.bold)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(Color.green.opacity(0.15))
                                .foregroundStyle(.green)
                                .clipShape(Capsule())
                        }
                        .padding()
                        .background(selectedEvent?.title == game ? Color.green.opacity(0.08) : Color.gray.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                }
                
                VStack(alignment: .leading, spacing: 10) {
                    Text("Venue Features")
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible()),
                            GridItem(.flexible()),
                            GridItem(.flexible())
                        ],
                        spacing: 18
                    ) {
                        VenueFeatureIcon(systemName: "tv.fill", title: "14 Screens", enabled: true)
                        VenueFeatureIcon(systemName: "projector.fill", title: "Projector", enabled: false)
                        VenueFeatureIcon(systemName: "wifi", title: "WiFi", enabled: true)
                        VenueFeatureIcon(systemName: "tree.fill", title: "Garden", enabled: false)
                        VenueFeatureIcon(systemName: "video.fill", title: "Projector", enabled: false)
                        VenueFeatureIcon(systemName: "pawprint.fill", title: "Pet Friendly", enabled: true)
                    }
                    .padding()
                    .background(Color.gray.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    FlowTags(tags: bar.tags)
                }
            }
            .padding()
        }
    }
    
    private func infoBox(title: String, subtitle: String, icon: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
            
            Text(title)
                .font(.headline)
                .lineLimit(1)
            
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
    
    private func actionButton(title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.title3)
                
                Text(title)
                    .font(.caption)
                    .fontWeight(.bold)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(color.opacity(0.12))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 18))
        }
    }
    private func experienceRow(_ title: String, _ value: String, _ icon: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(value)
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }

            Spacer()
        }
        .padding()
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
    
    
}

