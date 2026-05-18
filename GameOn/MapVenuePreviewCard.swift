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
    private var visibleLivePresenceProfiles: [UserProfileRow] {
        profiles.filter { $0.isFanVisibleForLivePresence(to: viewModel.currentUserAuthId) }
    }
    private var visiblePresenceLabel: String {
        if let first = visibleLivePresenceProfiles.first,
           let name = first.displayFirstName,
           goingCount > 1 {
            return "\(name) and \(goingCount - 1) fans going"
        }
        return goingCount == 1 ? "1 fan going" : "\(goingCount) fans going"
    }

    private var previewFeatureSummary: String {
        venueFeaturesForDisplay(bar)
            .prefix(3)
            .map(\.label)
            .joined(separator: " • ")
    }

    private var venueMiniStats: [VenueMiniStat] {
        [
            VenueMiniStat(vibeType: "packed", icon: "🔥", label: "On fire", tint: .orange),
            VenueMiniStat(vibeType: "seats_open", icon: "🪑", label: "Seats", tint: .green),
            VenueMiniStat(vibeType: "tv_visible", icon: "📺", label: "TVs", tint: .blue),
            VenueMiniStat(vibeType: "audio_on", icon: "🔊", label: "Sound", tint: .yellow),
            VenueMiniStat(vibeType: "crowd", icon: "👥", label: "Crowd", tint: .purple)
        ]
    }
    

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
                    
                    Text(previewFeatureSummary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            
            VStack(alignment: .leading, spacing: 10) {
                
                HStack(spacing: 10) {
                    if !visibleLivePresenceProfiles.isEmpty {
                        GoingAvatarStack(profiles: visibleLivePresenceProfiles, viewerUserID: viewModel.currentUserAuthId)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(visiblePresenceLabel)
                            .font(.subheadline.weight(.semibold))

                        Text("Live attendees")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)
                }

                FGWrappingLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                    previewSocialChip(goingCount == 1 ? "👥 1 fan" : "👥 \(goingCount) fans", tint: .red)
                    if visibleLivePresenceProfiles.isEmpty {
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
            
            VStack(alignment: .leading, spacing: 10) {
                if let venueEventID {
                    let energy = venuePreviewEnergy(for: venueEventID)
                    if energy.hasBadge {
                        venueGamePreviewEnergyHeader(energy)
                    }
                }

                Button {
                    if let venueEventID {
                        FanUpdatesTapPerf.handleTap(eventId: venueEventID) {
                            fanUpdatesSheetEvent = FanUpdatesSheetEvent(id: venueEventID)
                        }
                    }
                } label: {
                    fanChatRow(venueEventID: venueEventID)
                }
                .buttonStyle(FanUpdatesPressButtonStyle())
                .disabled(venueEventID == nil)

                if let venueEventID {
                    venueMiniStatsRow(venueEventID: venueEventID)
                }
            }
        .padding(.horizontal, 18)
        .padding(.bottom, 36)
        .background(.ultraThinMaterial)
        .background(Color.white.opacity(0.94))
        .clipShape(RoundedRectangle(cornerRadius: 32))
        .overlay {
            if let venueEventID {
                let energy = venuePreviewEnergy(for: venueEventID)
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .strokeBorder(venueGamePreviewEnergyTint(energy).opacity(energy.isHighEnergy ? 0.36 : 0), lineWidth: energy.isHighEnergy ? 1.25 : 0)
            }
        }
        .shadow(color: venueEventID.map { venuePreviewEnergy(for: $0) }.map { $0.isHighEnergy ? venueGamePreviewEnergyTint($0).opacity(0.12) : Color.clear } ?? Color.clear, radius: 10, x: 0, y: 3)
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

    private func fanChatRow(venueEventID: UUID?) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "bubble.left.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(FGColor.accentBlue)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text("Fan Chat")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(fanChatStatusText(venueEventID: venueEventID))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func fanChatStatusText(venueEventID: UUID?) -> String {
        guard let venueEventID else { return "0 new comments" }
        let commentCount = viewModel.fanUpdatesDisplayCommentCount(for: venueEventID)
        if commentCount >= 8 {
            return "\(commentCount) chatting now"
        }
        if commentCount > 0 {
            return commentCount == 1 ? "1 chatting now" : "\(commentCount) chatting now"
        }
        return "Fans reacting live"
    }

    private func venuePreviewEnergy(for venueEventID: UUID) -> VenueGamePreviewEnergy {
        let counts = viewModel.venueEventVibeCounts[venueEventID] ?? [:]
        let commentCount = viewModel.fanUpdatesDisplayCommentCount(for: venueEventID)
        let energy = VenueGamePreviewEnergy.evaluate(
            fireCount: counts["packed"] ?? 0,
            seatsCount: counts["seats_open"] ?? 0,
            tvCount: counts["tv_visible"] ?? 0,
            soundCount: counts["audio_on"] ?? 0,
            crowdCount: counts["crowd"] ?? 0,
            goingCount: goingCount,
            friendGoingCount: 0,
            commentCount: commentCount,
            isLiveNow: false,
            startsSoon: false
        )
        logVenueEnergyDebug(eventId: venueEventID, energy: energy)
        return energy
    }

    private func venueGamePreviewEnergyHeader(_ energy: VenueGamePreviewEnergy) -> some View {
        let tint = venueGamePreviewEnergyTint(energy)

        return VStack(alignment: .leading, spacing: 2) {
            Text(energy.label ?? "Quiet")
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .lineLimit(1)

            Text(energy.subtitle)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            Capsule(style: .continuous)
                .fill(tint.opacity(0.10))
        }
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(tint.opacity(0.24), lineWidth: 1)
        }
    }

    private func venueGamePreviewEnergyTint(_ energy: VenueGamePreviewEnergy) -> Color {
        switch energy.score {
        case 81...:
            return FGColor.accentBlue
        case 51...80:
            return .orange
        case 26...50:
            return .yellow
        case 10...25:
            return .green
        default:
            return .secondary
        }
    }

    private func venueMiniStatsRow(venueEventID: UUID) -> some View {
        let counts = viewModel.venueEventVibeCounts[venueEventID] ?? [:]
        let selected = viewModel.myVenueEventVibes[venueEventID] ?? []
        let _ = logVenueMiniStatsDebug(eventId: venueEventID, counts: counts)

        return HStack(spacing: 8) {
            ForEach(venueMiniStats) { stat in
                venueMiniStatChip(stat, venueEventID: venueEventID, counts: counts, selected: selected)
            }
        }
        .padding(.top, 1)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func venueMiniStatChip(
        _ stat: VenueMiniStat,
        venueEventID: UUID,
        counts: [String: Int],
        selected: Set<String>
    ) -> some View {
        let count = counts[stat.vibeType] ?? 0
        let isSelected = selected.contains(stat.vibeType)

        return Button {
            Task {
                await viewModel.toggleVibe(for: venueEventID, vibeType: stat.vibeType)
            }
        } label: {
            HStack(spacing: 3) {
                Text(stat.icon)
                Text("\(count)")
                    .fontWeight(.heavy)
                    .monospacedDigit()
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(isSelected ? .white : stat.tint)
            .lineLimit(1)
            .minimumScaleFactor(0.88)
            .padding(.horizontal, 5)
            .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30)
            .background(
                Capsule(style: .continuous)
                    .fill(isSelected ? stat.tint.opacity(0.88) : stat.tint.opacity(0.10))
            )
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(stat.tint.opacity(isSelected ? 0.68 : 0.24), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(stat.label), \(count) \(count == 1 ? "vote" : "votes")")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func logVenueMiniStatsDebug(eventId: UUID, counts: [String: Int]) {
#if DEBUG
        print("[VenueMiniStatsDebug] eventId=\(eventId.uuidString)")
        print("[VenueMiniStatsDebug] packed=\(counts["packed"] ?? 0)")
        print("[VenueMiniStatsDebug] seats=\(counts["seats_open"] ?? 0)")
        print("[VenueMiniStatsDebug] tv=\(counts["tv_visible"] ?? 0)")
        print("[VenueMiniStatsDebug] sound=\(counts["audio_on"] ?? 0)")
        print("[VenueMiniStatsDebug] crowd=\(counts["crowd"] ?? 0)")
        print("[VenueMiniStatsDebug] rowRendered=true")
#endif
    }

    private func logVenueEnergyDebug(eventId: UUID, energy: VenueGamePreviewEnergy) {
#if DEBUG
        print("[VenueEnergyDebug] eventId=\(eventId.uuidString)")
        print("[VenueEnergyDebug] score=\(energy.score)")
        print("[VenueEnergyDebug] label=\(energy.label ?? "none")")
        print("[VenueEnergyDebug] fire=\(energy.fireCount)")
        print("[VenueEnergyDebug] crowd=\(energy.crowdCount)")
        print("[VenueEnergyDebug] going=\(energy.goingCount)")
        print("[VenueEnergyDebug] friends=\(energy.friendGoingCount)")
        print("[VenueEnergyDebug] comments=\(energy.commentCount)")
#endif
    }
}

private extension UserProfileRow {
    var displayFirstName: String? {
        let display = (display_name ?? username ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !display.isEmpty else { return nil }
        return display.split(separator: " ").first.map(String.init)
    }
}

private struct VenueMiniStat: Identifiable {
    let vibeType: String
    let icon: String
    let label: String
    let tint: Color

    var id: String { vibeType }
}
