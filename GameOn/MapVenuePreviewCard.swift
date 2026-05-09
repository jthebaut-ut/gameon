import SwiftUI

struct MapVenuePreviewCard: View {

    @ObservedObject var viewModel: MapViewModel
    
    let bar: BarVenue
    let gamesTodayCount: Int
    let goingCount: Int
    let profiles: [UserProfileRow]
    let isFavorite: Bool
    let venueEventID: UUID?

    let onFavorite: () -> Void
    let onGoing: () -> Void
    
    let onDirections: () -> Void
    let onDetails: () -> Void
    
    @State private var selectedCommentsEventID: UUID?
    

    var body: some View {
        
        VStack(spacing: 14) {
            
            Capsule()
                .fill(Color.gray.opacity(0.35))
                .frame(width: 42, height: 5)
                .padding(.top, 8)
            
            HStack(alignment: .top, spacing: 14) {
                
                venueImage
                
                VStack(alignment: .leading, spacing: 7) {
                    
                    HStack(alignment: .top) {
                        
                        Text(bar.name)
                            .font(.title2.bold())
                        
                        Spacer()
                        
                        Button(action: onFavorite) {
                            Image(systemName: isFavorite ? "heart.fill" : "heart")
                                .font(.title2)
                                .foregroundStyle(isFavorite ? .red : .black)
                        }
                    }
                    
                    HStack(spacing: 8) {
                        
                        Text(bar.distance.isEmpty ? "0.4 mi" : bar.distance)
                            .foregroundStyle(.secondary)
                        
                        Text("•")
                            .foregroundStyle(.secondary)
                        
                        Text("Open until 2:00 AM")
                            .foregroundStyle(.green)
                    }
                    .font(.subheadline)
                    
                    HStack(spacing: 8) {
                        
                        Image(systemName: "soccerball")
                        Image(systemName: "basketball.fill")
                        
                        Text("\(gamesTodayCount) games today")
                            .font(.subheadline)
                    }
                    
                    Text("🔥 \(goingCount) people going")
                        .font(.headline)
                        .foregroundStyle(.red)
                    
                    Text("Great crowd • Multiple screens • Full audio")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            
            HStack(spacing: 12) {
                
                GoingAvatarStack(profiles: profiles)
                
                VStack(alignment: .leading, spacing: 2) {
                    
                    Text("\(goingCount) people going")
                        .font(.subheadline.weight(.semibold))
                    
                    Text("Live attendees")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Button(action: onGoing) {
                    
                    Text("I'm going")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 13)
                        .background(Color.black)
                        .clipShape(Capsule())
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 22)
                    .fill(Color.white)
            )
            
            Button {
                if let venueEventID {
                    selectedCommentsEventID = venueEventID
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "bubble.left")

                    Text("Recent updates")

                    Text("Tap to view")
                        .fontWeight(.medium)

                    Spacer()

                    Image(systemName: "chevron.right")
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)
            }
            .disabled(venueEventID == nil)
        .padding(.horizontal, 18)
        .padding(.bottom, 18)
        .background(.ultraThinMaterial)
        .background(Color.white.opacity(0.94))
        .clipShape(RoundedRectangle(cornerRadius: 32))
        .shadow(color: .black.opacity(0.15), radius: 18, x: 0, y: 8)
        .padding(.horizontal, 16)
            
        .sheet(isPresented: Binding(
            get: { selectedCommentsEventID != nil },
            set: { if !$0 { selectedCommentsEventID = nil } }
        )) {
            if let eventID = selectedCommentsEventID {
                VenueEventCommentsSheet(
                    viewModel: viewModel,
                    venueEventID: eventID
                )
            }
        }
        }
            
    
        HStack {
            Button(action: onDirections) {
                Label("Directions", systemImage: "map.fill")
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.black)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }

            Button(action: onDetails) {
                Text("Details")
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.primary.opacity(0.10))
                    .foregroundStyle(.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
        }
        
    }

    private var venueImage: some View {

        ZStack(alignment: .bottomLeading) {

            if let urlString = ImageDisplayURL.forList(thumbnail: bar.coverPhotoThumbnailURL, full: bar.coverPhotoURL),
               let url = URL(string: urlString) {

                DiscoverCachedRemoteImage(url: url, contentMode: .fill) {
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                }

            } else {

                Rectangle()
                    .fill(Color.gray.opacity(0.2))
            }

            Text("🔥 Most popular")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.65))
                .clipShape(Capsule())
                .padding(8)
        }
        .frame(width: 135, height: 112)
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}
