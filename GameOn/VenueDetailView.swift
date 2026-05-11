import SwiftUI

struct VenueDetailView: View {
    let bar: BarVenue
    let selectedEvent: SportsEvent?
    let isFavorite: Bool
    let goingCount: Int
    let iconForSport: (String) -> String
    /// When nil, falls back to ``BarVenue/rating``.
    var mergedRating: Double? = nil
    var reviewCountText: String? = nil
    let onDirections: () -> Void
    let onCall: () -> Void
    let onFavorite: () -> Void
    var onAddressTap: (() -> Void)? = nil
    var onRateVenue: (() -> Void)? = nil
    let experience: VenueExperience?
    var coverPhotoURL: String? = nil
    var menuPhotoURL: String? = nil
    /// Discover “Claim this business” → venue owner flow (optional so other call sites compile).
    var onClaimThisBusiness: ((BarVenue) -> Void)? = nil
    /// When true (business owner viewing their own linked venue), show informational copy instead of the claim action.
    var venueAlreadyManagedBySignedInBusiness: Bool = false

    private var resolvedRating: Double {
        mergedRating ?? bar.rating
    }

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

                        Button {
                            (onAddressTap ?? onDirections)()
                        } label: {
                            Text(bar.address)
                                .font(.subheadline)
                                .foregroundStyle(.blue)
                                .multilineTextAlignment(.leading)
                        }
                        .buttonStyle(.plain)
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
                    if let onRateVenue {
                        Button(action: onRateVenue) {
                            infoBox(
                                title: String(format: "%.1f", resolvedRating),
                                subtitle: reviewCountText ?? "Reviews",
                                icon: "star.fill"
                            )
                        }
                        .buttonStyle(.plain)
                    } else {
                        infoBox(
                            title: String(format: "%.1f", resolvedRating),
                            subtitle: reviewCountText ?? "Rating",
                            icon: "star.fill"
                        )
                    }
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

                if venueAlreadyManagedBySignedInBusiness {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            Image(systemName: "building.2.fill")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Managed by your business")
                                    .font(.subheadline.weight(.semibold))
                                Text("This location is already linked to your business account.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(Color.primary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                    }
                } else if let onClaimThisBusiness {
                    VStack(alignment: .leading, spacing: 6) {
                        Button {
                            onClaimThisBusiness(bar)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "building.2.crop.circle")
                                    .font(.title3)
                                Text("Claim this business")
                                    .font(.subheadline.weight(.semibold))
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.orange.opacity(0.14))
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                        }
                        .buttonStyle(.plain)

                        Text("Claim requests are reviewed before owner tools are enabled.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Games Showing")
                        .font(.title2)
                        .fontWeight(.bold)

                    if bar.games.isEmpty {
                        Text("No games listed yet.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .background(Color.gray.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    } else {
                        ForEach(Array(bar.games.enumerated()), id: \.offset) { _, game in
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
                }
                
                VStack(alignment: .leading, spacing: 12) {
                    VenuePublicFeaturesCard(bar: bar)
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

