import SwiftUI

/// Liquid Glass “Your rating” sheet for a venue (local save via ``MapViewModel``).
struct VenueUserRatingSheet: View {
    @ObservedObject var viewModel: MapViewModel
    let bar: BarVenue
    @Environment(\.dismiss) private var dismiss

    @State private var selectedStars: Int = 4

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Text(bar.name)
                    .font(.title3.weight(.bold))
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)

                Text("Your rating")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    ForEach(1...5, id: \.self) { n in
                        Button {
                            selectedStars = n
                        } label: {
                            Image(systemName: n <= selectedStars ? "star.fill" : "star")
                                .font(.system(size: 36, weight: .bold))
                                .foregroundStyle(n <= selectedStars ? Color.yellow : Color.gray.opacity(0.35))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Rating \(selectedStars) stars")

                Spacer(minLength: 0)

                Button {
                    viewModel.saveUserVenueRating(venueID: bar.id, stars: selectedStars)
                    dismiss()
                } label: {
                    Text("Save")
                        .font(.headline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .foregroundStyle(.white)
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .padding(.bottom, 12)
            }
            .padding(.horizontal, 22)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                    .padding(.vertical, 8)
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .onAppear {
            if let existing = viewModel.venueUserStarRatings[bar.id] {
                selectedStars = existing
            }
        }
    }
}
