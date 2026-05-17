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
    
    @State private var fanUpdatesSheetEvent: FanUpdatesSheetEvent?
    @State private var fanFeatureBlockedMessage: String?
    

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
                        
                        Button {
                            if viewModel.canFavoriteVenues {
                                onFavorite()
                            } else if viewModel.isAuthenticatedForSocialFeatures {
                                viewModel.logBusinessUserGateBlocked(action: "favoriteVenue")
                                fanFeatureBlockedMessage = BusinessFanGateCopy.actionTapBlocked
                            } else {
                                onFavorite()
                            }
                        } label: {
                            Image(systemName: isFavorite ? "heart.fill" : "heart")
                                .font(.title2)
                                .foregroundStyle(isFavorite ? .red : .black)
                        }
                        .opacity(viewModel.canFavoriteVenues || !viewModel.isAuthenticatedForSocialFeatures ? 1 : 0.45)
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
                    
                    Text(goingCount == 1 ? "👥 1 fan going" : "👥 \(goingCount) fans going")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.red)
                    
                    Text("Great crowd • Multiple screens • Full audio")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            
            VStack(alignment: .leading, spacing: 10) {
                
                HStack(spacing: 10) {
                    GoingAvatarStack(profiles: profiles)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(goingCount == 1 ? "1 fan going" : "\(goingCount) fans going")
                            .font(.subheadline.weight(.semibold))

                        Text("Live attendees")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)
                }

                FGWrappingLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                    previewSocialChip(goingCount == 1 ? "👥 1 fan" : "👥 \(goingCount) fans", tint: .red)
                    if profiles.isEmpty {
                        previewSocialChip("Start the crowd", tint: .secondary)
                    } else {
                        previewSocialChip("Friends going", tint: .blue)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack {
                    Spacer(minLength: 0)

                    Button {
                        if viewModel.canMarkGoing {
                            onGoing()
                        } else if viewModel.isAuthenticatedForSocialFeatures {
                            viewModel.logBusinessUserGateBlocked(action: "markGoing")
                            fanFeatureBlockedMessage = BusinessFanGateCopy.actionTapBlocked
                        } else {
                            onGoing()
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark")
                                .font(.caption.weight(.bold))
                            Text("Going")
                                .font(.caption.weight(.bold))
                        }
                        .foregroundStyle(.black)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.08))
                        .overlay {
                            Capsule(style: .continuous)
                                .strokeBorder(Color.black.opacity(0.16), lineWidth: 1)
                        }
                        .clipShape(Capsule(style: .continuous))
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    .opacity(viewModel.canMarkGoing || !viewModel.isAuthenticatedForSocialFeatures ? 1 : 0.45)
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 22)
                    .fill(Color.white)
            )
            
            Button {
                if let venueEventID {
                    FanUpdatesTapPerf.handleTap(eventId: venueEventID) {
                        fanUpdatesSheetEvent = FanUpdatesSheetEvent(id: venueEventID)
                    }
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
            .buttonStyle(FanUpdatesPressButtonStyle())
            .disabled(venueEventID == nil)
        .padding(.horizontal, 18)
        .padding(.bottom, 18)
        .background(.ultraThinMaterial)
        .background(Color.white.opacity(0.94))
        .clipShape(RoundedRectangle(cornerRadius: 32))
        .shadow(color: .black.opacity(0.15), radius: 18, x: 0, y: 8)
        .padding(.horizontal, 16)
            
        .sheet(item: $fanUpdatesSheetEvent) { event in
            VenueEventCommentsSheet(
                viewModel: viewModel,
                venueEventID: event.id
            )
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
        .alert(
            "FanGeo",
            isPresented: Binding(
                get: { fanFeatureBlockedMessage != nil },
                set: { if !$0 { fanFeatureBlockedMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { fanFeatureBlockedMessage = nil }
        } message: {
            Text(fanFeatureBlockedMessage ?? "")
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

    private func previewSocialChip(_ title: String, tint: Color) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(tint.opacity(0.10))
            .clipShape(Capsule(style: .continuous))
    }
}
