import SwiftUI

struct VenueEventVibeMeterView: View {
    @ObservedObject var viewModel: MapViewModel
    let venueEventID: UUID

    private let vibes: [(type: String, label: String)] = [
        ("audio_on", "🔊 Audio"),
        ("packed", "🔥 Packed"),
        ("seats_open", "🪑 Seats"),
        ("specials", "🍺 Specials")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Live vibe")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(vibes, id: \.type) { vibe in
                        vibeButton(type: vibe.type, label: vibe.label)
                    }
                }
            }
        }
        .task {
            await viewModel.loadVibes(for: venueEventID)
        }
    }

    private func vibeButton(type: String, label: String) -> some View {
        let count = viewModel.venueEventVibeCounts[venueEventID]?[type] ?? 0
        let isSelected = viewModel.myVenueEventVibes[venueEventID]?.contains(type) ?? false

        return Button {
            Task {
                await viewModel.toggleVibe(for: venueEventID, vibeType: type)
            }
        } label: {
            Text("\(label) \(count)")
                .font(.caption)
                .fontWeight(.bold)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(isSelected ? Color.black : Color.gray.opacity(0.12))
                .foregroundStyle(isSelected ? .white : .primary)
                .clipShape(Capsule())
        }
    }
}
