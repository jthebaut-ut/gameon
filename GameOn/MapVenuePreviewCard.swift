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
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode
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

    private var discoverCardCoverURLString: String? {
        ImageDisplayURL.forList(thumbnail: bar.coverPhotoThumbnailURL, full: bar.coverPhotoURL)
    }

    private var discoverCardUsesThumbnail: Bool {
        let thumbnail = bar.coverPhotoThumbnailURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !thumbnail.isEmpty && discoverCardCoverURLString == thumbnail
    }

    private var venueMiniStats: [VenueMiniStat] {
        [
            VenueMiniStat(vibeType: "packed", icon: "🔥", label: "On fire", countColor: .red, background: Color(red: 1.00, green: 0.90, blue: 0.92), selectedBackground: .red.opacity(0.18)),
            VenueMiniStat(vibeType: "seats_open", icon: "🪑", label: "Seats", countColor: .green, background: Color(red: 0.90, green: 0.97, blue: 0.91), selectedBackground: .green.opacity(0.18)),
            VenueMiniStat(vibeType: "tv_visible", icon: "📺", label: "TVs", countColor: .primary, background: Color(red: 0.90, green: 0.95, blue: 1.00), selectedBackground: .blue.opacity(0.18)),
            VenueMiniStat(vibeType: "audio_on", icon: "🔊", label: "Sound", countColor: .orange, background: Color(red: 1.00, green: 0.96, blue: 0.84), selectedBackground: .yellow.opacity(0.24)),
            VenueMiniStat(vibeType: "crowd", icon: "👥", label: "Crowd", countColor: .blue, background: Color(red: 0.92, green: 0.93, blue: 1.00), selectedBackground: .blue.opacity(0.16))
        ]
    }
    

    var body: some View {
        let previewEnergy = venueEventID.map { venuePreviewEnergy(for: $0) }
        let energyPalette = venueGamePreviewEnergyPalette(previewEnergy)
        
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
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 22)
                    .fill(Color.white)
            )
            
            VStack(alignment: .leading, spacing: 10) {
                if let previewEnergy, previewEnergy.hasBadge {
                    venueGamePreviewEnergyHeader(previewEnergy)
                }

                mapVenuePreviewGameActionRow(venueEventID: venueEventID)

                if let venueEventID {
                    venueMiniStatsRow(venueEventID: venueEventID)
                }
            }
        .padding(.horizontal, 18)
        .padding(.bottom, 36)
        .background(.ultraThinMaterial)
        .background(Color.white.opacity(0.94))
        .background(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(energyPalette.auraColor)
                .blur(radius: 18)
                .opacity(previewEnergy?.hasBadge == true ? 1 : 0)
        )
        .overlay(alignment: .top) {
            if previewEnergy?.hasBadge == true {
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: energyPalette.topEdgeColors,
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(height: 3)
                    .padding(.horizontal, 34)
                    .padding(.top, 1)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 32))
        .shadow(color: energyPalette.glowColor, radius: energyPalette.glowRadius, x: 0, y: 5)
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
                Label(L10n.t("directions", languageCode: appLanguageRaw), systemImage: "map.fill")
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.black)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }

            Button(action: onDetails) {
                Text(L10n.t("details", languageCode: appLanguageRaw))
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
        let coverURLString = discoverCardCoverURLString

        return ZStack(alignment: .bottomLeading) {

            if let urlString = coverURLString,
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
        .onAppear {
            logDiscoverCardPhotoDebug(urlString: coverURLString)
            logVenueFeatureCardPropagation()
        }
    }

    private func logDiscoverCardPhotoDebug(urlString: String?) {
#if DEBUG
        let resolved = urlString ?? ""
        print("[VenuePhotoDisplayDebug] discoverCardCoverURL=\(resolved)")
        print("[VenuePhotoDisplayDebug] usingThumbnail=\(discoverCardUsesThumbnail)")
        print("[VenuePhotoDisplayDebug] fallbackUsed=\(resolved.isEmpty)")
#endif
    }

    private func logVenueFeatureCardPropagation() {
#if DEBUG
        print("[VenueFeatureDebug] propagatedToVenueCard=true")
        print("[VenueFeatureDebug] discoverCardFeatureChipsRemoved=true")
        print("[VenueFeatureDebug] sourceOfTruth=venues.features,venues.screen_count,venues.serves_food,venues.has_wifi,venues.has_garden,venues.has_projector,venues.pet_friendly")
        if bar.hasBusinessVerifiedFeatures {
            print("[VenueFeatureDebug] approvedBusinessVenueFeaturesVerified=true")
        }
#endif
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

    @ViewBuilder
    private func mapVenuePreviewGameActionRow(venueEventID: UUID?) -> some View {
        let source = "mapVenuePreviewCard"
        let commentCount = venueEventID.map { viewModel.fanUpdatesDisplayCommentCount(for: $0) } ?? 0
        if let venueEventID {
            let _ = logFanChatEntryUXRendered(source: source, eventId: venueEventID, count: commentCount)
        }

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button {
                    if let venueEventID {
                        print("[GoingButtonDebug] tap eventId=\(venueEventID.uuidString.lowercased())")
                    } else {
                        print("[GoingButtonDebug] tap eventId=nil venue=\(bar.name)")
                    }
                    if viewModel.canMarkGoing {
                        onGoing()
                    } else if viewModel.isAuthenticatedForSocialFeatures {
                        print("[GoingButtonDebug] blocked reason=businessAccount")
                        viewModel.logBusinessUserGateBlocked(action: "markGoing")
                        fanFeatureBlockedMessage = BusinessFanGateCopy.actionTapBlocked
                    } else {
                        onGoing()
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                        Text(L10n.t("going", languageCode: appLanguageRaw))
                            .font(.caption.weight(.bold))
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .background(Color.black.opacity(0.08))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(Color.black.opacity(0.16), lineWidth: 1)
                    }
                    .clipShape(Capsule(style: .continuous))
                    .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(.plain)
                .opacity(viewModel.canMarkGoing || !viewModel.isAuthenticatedForSocialFeatures ? 1 : 0.45)

                if let venueEventID {
                    mapVenueFanChatActionButton(
                        venueEventID: venueEventID,
                        source: source,
                        commentCount: commentCount
                    )
                }

                Spacer(minLength: 0)
            }

            if commentCount == 0, venueEventID != nil {
                Text("Join the game conversation")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func mapVenueFanChatActionButton(
        venueEventID: UUID,
        source: String,
        commentCount: Int
    ) -> some View {
        let baseTitle = "Chat"
        let title = commentCount > 0 ? "\(baseTitle) · \(commentCount)" : baseTitle
        let tint = FGColor.accentBlue
        let fill = tint.opacity(colorScheme == .dark ? 0.20 : 0.12)

        return Button {
            print(
                "[FanChatEntryUX] tapped source=\(source) eventId=\(venueEventID.uuidString.lowercased())"
            )
            FanUpdatesTapPerf.handleTap(eventId: venueEventID) {
                fanUpdatesSheetEvent = FanUpdatesSheetEvent(id: venueEventID)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                Text(title)
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background {
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
                    .background {
                        Capsule(style: .continuous)
                            .fill(fill)
                    }
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(tint.opacity(colorScheme == .dark ? 0.34 : 0.26), lineWidth: 1)
            }
            .fixedSize(horizontal: true, vertical: false)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            commentCount > 0
                ? "Chat, \(commentCount) comments"
                : "Chat"
        )
    }

    private func logFanChatEntryUXRendered(source: String, eventId: UUID, count: Int) {
        print(
            "[FanChatEntryUX] rendered source=\(source) eventId=\(eventId.uuidString.lowercased()) count=\(count)"
        )
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
        let palette = venueGamePreviewEnergyPalette(energy)

        return VStack(alignment: .leading, spacing: 2) {
            Text("\(energy.label ?? "Quiet") • \(energy.score)")
                .font(.caption.weight(.bold))
                .foregroundStyle(palette.text)
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
                .fill(energyGradient(for: energy.score))
        }
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: palette.borderColors,
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    lineWidth: 1
                )
        }
        .shadow(color: palette.glowColor, radius: palette.glowRadius, x: 0, y: 3)
    }

    private func venueGamePreviewEnergyPalette(_ energy: VenueGamePreviewEnergy?) -> VenueEnergyColorPalette {
        venueEnergyColorPalette(for: energy?.score ?? 0)
    }

    private func venueMiniStatsRow(venueEventID: UUID) -> some View {
        let counts = viewModel.venueEventVibeCounts[venueEventID] ?? [:]
        let selected = viewModel.myVenueEventVibes[venueEventID] ?? []
        let _ = logVenueMiniStatsDebug(eventId: venueEventID, counts: counts)

        return HStack(spacing: 6) {
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
            HStack(spacing: 4) {
                Text(stat.icon)
                    .font(.system(size: 17))
                Text("\(count)")
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(stat.countColor)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 38, maxHeight: 38)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isSelected ? stat.selectedBackground : stat.background)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(stat.label), \(count) \(count == 1 ? "vote" : "votes")")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func logVenueMiniStatsDebug(eventId: UUID, counts: [String: Int]) {
#if DEBUG
        guard VenueGameCardDiagnostics.enabled else { return }
        print("[VenueMiniStatsDebug] eventId=\(eventId.uuidString)")
        print("[VenueMiniStatsDebug] counts=packed:\(counts["packed"] ?? 0),seats:\(counts["seats_open"] ?? 0),tv:\(counts["tv_visible"] ?? 0),sound:\(counts["audio_on"] ?? 0),crowd:\(counts["crowd"] ?? 0)")
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
        let palette = venueGamePreviewEnergyPalette(energy)
        print("[VenueEnergyColorDebug] score=\(energy.score)")
        print("[VenueEnergyColorDebug] tier=\(palette.tier.rawValue)")
        print("[VenueEnergyColorDebug] accent=\(String(describing: energyAccentColor(for: energy.score)))")
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
    let countColor: Color
    let background: Color
    let selectedBackground: Color

    var id: String { vibeType }
}

