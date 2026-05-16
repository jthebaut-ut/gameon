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
