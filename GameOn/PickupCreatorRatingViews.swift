import SwiftUI

struct PickupCreatorTrustLineView: View {
    let stats: PickupCreatorPublicRatingStats?
    /// When true (pickup **detail** sheet), show a loading row until RPC stats arrive; lists keep empty space until loaded.
    var detailAlwaysVisible: Bool = false
    /// Stronger typography on the pickup detail **Organizer** tile so the rating line is easy to scan.
    var organizerCardRatingEmphasis: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let stats {
                let line = detailAlwaysVisible ? stats.pickupOrganizerDetailRatingLine : stats.organizerTrustSummaryLine
                Text(line)
                    .font(
                        organizerCardRatingEmphasis
                            ? .caption.weight(.semibold)
                            : FGTypography.metadata.weight(.medium)
                    )
                    .foregroundStyle(
                        organizerCardRatingEmphasis
                            ? FGColor.primaryText(colorScheme)
                            : FGColor.secondaryText(colorScheme)
                    )
                    .lineLimit(organizerCardRatingEmphasis ? 1 : nil)
                    .minimumScaleFactor(organizerCardRatingEmphasis ? 0.72 : 1)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(
                        stats.ratingCount > 0
                            ? "Organizer rating \(line)"
                            : "Organizer trust: new organizer, no ratings yet"
                    )
            } else if detailAlwaysVisible {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading organizer trust…")
                        .font(FGTypography.metadata.weight(.medium))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Loading organizer trust")
            }
        }
    }
}

struct PickupOrganizerPreviewIdentityRow: View {
    @ObservedObject var viewModel: MapViewModel
    let organizerUserId: UUID
    let stats: PickupCreatorPublicRatingStats?
    let colorScheme: ColorScheme

    private var displayName: String {
        viewModel.pickupCreatorDisplayLabel(for: organizerUserId) ?? ""
    }

    private var emailLine: String {
        viewModel.pickupOrganizerEmailForDetail(userId: organizerUserId)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            UserAvatarView(
                avatarThumbnailURL: viewModel.pickupOrganizerAvatarThumbnailForDetail(userId: organizerUserId),
                avatarURL: viewModel.pickupOrganizerAvatarFullForDetail(userId: organizerUserId),
                avatarDisplayRefreshToken: viewModel.pickupOrganizerAvatarRefreshTokenForDetail(userId: organizerUserId),
                displayName: displayName,
                email: emailLine,
                size: 32,
                fallbackStyle: colorScheme == .dark ? .darkCardTranslucent : .lightOnWhiteChrome,
                imagePlaceholderTint: colorScheme == .dark ? .white.opacity(0.72) : nil
            )
            .background {
                Circle()
                    .fill(colorScheme == .dark ? Color.white.opacity(0.10) : Color(white: 0.88))
            }
            .overlay {
                Circle()
                    .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.28 : 0.58), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.12), radius: 5, x: 0, y: 2)

            VStack(alignment: .leading, spacing: 1) {
                if !displayName.isEmpty {
                    Text("\(displayName) • Organizer")
                        .font(FGTypography.metadata.weight(.semibold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }

                PickupCreatorTrustLineView(stats: stats)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        let organizer = displayName.isEmpty ? "Organizer" : "\(displayName), organizer"
        let trust = stats?.organizerTrustSummaryLine ?? "Organizer trust loading"
        return "\(organizer). \(trust)"
    }
}

/// Public profile organizer reputation (reuses ``PickupCreatorPublicRatingStats`` / ``pickupOrganizerDetailRatingLine``).
struct PublicProfilePickupOrganizerCard: View {
    let creatorUserId: UUID
    let stats: PickupCreatorPublicRatingStats?

    @Environment(\.colorScheme) private var colorScheme

    private var resolved: PickupCreatorPublicRatingStats {
        stats ?? PickupCreatorPublicRatingStats(avgRating: 0, ratingCount: 0)
    }

    private var isRated: Bool {
        resolved.hasPublicOrganizerRatings
    }

    private var ratingAccent: Color {
        if !isRated { return FGColor.secondaryText(colorScheme) }
        if resolved.avgRating >= 4.5 { return FGColor.accentGreen }
        if resolved.avgRating >= 4.0 { return FGColor.accentGreen.opacity(0.88) }
        return FGColor.secondaryText(colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "person.3.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(FGColor.accentBlue)
                Text("Pickup Organizer")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
                    .textCase(.uppercase)
                    .tracking(0.7)
                Spacer(minLength: 0)
                if let tier = resolved.publicProfileOrganizerTierLabel {
                    Text(tier)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(isRated ? FGColor.accentGreen : FGColor.secondaryText(colorScheme))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background {
                            Capsule(style: .continuous)
                                .fill(
                                    isRated
                                        ? FGColor.accentGreen.opacity(colorScheme == .dark ? 0.16 : 0.11)
                                        : Color.white.opacity(colorScheme == .dark ? 0.07 : 0.72)
                                )
                        }
                        .overlay {
                            Capsule(style: .continuous)
                                .strokeBorder(
                                    isRated ? FGColor.accentGreen.opacity(0.28) : FGColor.divider(colorScheme),
                                    lineWidth: 1
                                )
                        }
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "star.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ratingAccent)
                Text(resolved.pickupOrganizerDetailRatingLine)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(ratingAccent)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }

            Text(resolved.publicProfileOrganizerTrustCopy)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(FGColor.mutedText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(colorScheme == .dark ? 0.065 : 0.96),
                            FGColor.accentBlue.opacity(colorScheme == .dark ? 0.07 : 0.06),
                            FGColor.accentGreen.opacity(colorScheme == .dark ? 0.045 : 0.055)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(colorScheme == .dark ? 0.10 : 0.82),
                            isRated ? FGColor.accentGreen.opacity(0.16) : FGColor.accentBlue.opacity(colorScheme == .dark ? 0.12 : 0.14)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.75
                )
        }
        .shadow(color: FGColor.accentBlue.opacity(colorScheme == .dark ? 0.10 : 0.08), radius: 12, y: 7)
        .onAppear {
            PickupOrganizerReputationDebug.log(creatorUserId: creatorUserId, stats: stats)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        let line = resolved.pickupOrganizerDetailRatingLine
        let copy = resolved.publicProfileOrganizerTrustCopy
        if let tier = resolved.publicProfileOrganizerTierLabel {
            return "Pickup organizer. \(tier). \(line). \(copy)"
        }
        return "Pickup organizer. \(line). \(copy)"
    }
}

/// Compact post-game organizer rating (approved joiners only; parent gates visibility).
struct PickupCreatorRatingPromptCard: View {
    @ObservedObject var viewModel: MapViewModel
    let game: PickupGameRow

    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedRating: Int = 0
    @State private var feedback: String = ""
    @State private var thanks = false
    @State private var isSubmitting = false
    @State private var submitError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: FGSpacing.sm) {
            if thanks {
                HStack(alignment: .center, spacing: FGSpacing.sm) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(FGColor.accentGreen)
                    Text("Thanks for rating.")
                        .font(FGTypography.cardTitle.weight(.semibold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("How was this pickup game?")
                    .font(FGTypography.cardTitle)
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                Text("Rate the organizer")
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))

                HStack(spacing: 6) {
                    ForEach(1 ... 5, id: \.self) { n in
                        Button {
                            selectedRating = n
                        } label: {
                            Image(systemName: n <= selectedRating ? "star.fill" : "star")
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(n <= selectedRating ? FGColor.accentYellow : FGColor.mutedText(colorScheme))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(n) stars")
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Star rating")

                Text("Anything to add?")
                    .font(FGTypography.metadata.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .padding(.top, 4)

                TextField("Optional feedback", text: $feedback, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2 ... 4)
                    .font(FGTypography.caption)

                if let submitError, !submitError.isEmpty {
                    Text(submitError)
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.dangerRed)
                }

                Button {
                    Task { await submit() }
                } label: {
                    Text(isSubmitting ? "Submitting…" : "Submit rating")
                        .font(FGTypography.caption.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(FGColor.accentBlue)
                .disabled(selectedRating < 1 || selectedRating > 5 || isSubmitting)
            }
        }
        .padding(FGSpacing.md)
        .background(FGColor.cardBackground(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FGRadius.card, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
        }
    }

    private func submit() async {
        guard selectedRating >= 1, selectedRating <= 5 else { return }
        isSubmitting = true
        submitError = nil
        let ok = await viewModel.submitPickupCreatorRating(
            pickupGameId: game.id,
            creatorUserId: game.creator_user_id,
            rating: selectedRating,
            feedback: feedback
        )
        isSubmitting = false
        if ok {
            thanks = true
        } else {
            submitError = "Couldn’t save your rating. Try again in a moment."
        }
    }
}
