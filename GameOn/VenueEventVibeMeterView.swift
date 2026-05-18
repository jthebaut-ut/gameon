import SwiftUI

struct VenueEventVibeMeterView: View {
    let viewModel: MapViewModel
    @ObservedObject var fanUpdatesStore: FanUpdatesRealtimeStore
    let venueEventID: UUID
    @State private var chipsVisible = false

    private let vibes: [(type: String, label: String)] = [
        ("audio_on", "🔊 Audio"),
        ("packed", "🔥 Packed"),
        ("seats_open", "🪑 Seats"),
        ("tv_visible", "📺 TVs"),
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
                            .progressiveAppear(isVisible: chipsVisible, yOffset: 4)
                    }
                }
                .animation(.easeOut(duration: 0.2), value: fanUpdatesStore.venueEventVibeCounts[venueEventID]?.values.reduce(0, +) ?? 0)
            }
        }
        .task {
            withAnimation(.easeOut(duration: 0.2)) {
                chipsVisible = true
            }
            viewModel.prefetchVibesForFanUpdatesCardIfNeeded(venueEventID: venueEventID)
        }
    }

    private func vibeButton(type: String, label: String) -> some View {
        let count = fanUpdatesStore.venueEventVibeCounts[venueEventID]?[type] ?? 0
        let isSelected = fanUpdatesStore.myVenueEventVibes[venueEventID]?.contains(type) ?? false

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
