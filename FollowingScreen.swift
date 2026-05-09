import SwiftUI

struct FollowingScreen: View {
    @ObservedObject var viewModel: MapViewModel
    
    var favoriteVenues: [BarVenue] {
        viewModel.bars.filter {
            viewModel.favoriteVenueIDs.contains($0.id)
        }
    }
    
    var goingPlans: [(bar: BarVenue, gameTitle: String, count: Int)] {
        viewModel.interestedPlans()
    }
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.94)
                .ignoresSafeArea()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    
                    Text("Following")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .padding(.top, 22)
                    
                    Text("Your saved venues and games you plan to attend.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                    
                    sectionTitle("I’m Going")
                    
                    if goingPlans.isEmpty {
                        emptyCard(
                            icon: "person.badge.plus",
                            title: "No plans yet",
                            subtitle: "Tap “I’m going” on a venue event to add it here."
                        )
                    } else {
                        VStack(spacing: 12) {
                            ForEach(Array(goingPlans.enumerated()), id: \.offset) { _, plan in
                                goingPlanCard(plan)
                            }
                        }
                    }
                    
                    sectionTitle("Saved Venues")
                    
                    if favoriteVenues.isEmpty {
                        emptyCard(
                            icon: "heart",
                            title: "No saved venues yet",
                            subtitle: "Tap the heart on a venue to save it."
                        )
                    } else {
                        VStack(spacing: 12) {
                            ForEach(favoriteVenues) { bar in
                                venueCard(bar)
                            }
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 110)
            }
        }
    }
    
    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .fontWeight(.bold)
            .foregroundStyle(.white)
    }
    
    private func emptyCard(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.largeTitle)
                .foregroundStyle(.white.opacity(0.7))
            
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
            
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color.white.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }
    
    private func goingPlanCard(_ plan: (bar: BarVenue, gameTitle: String, count: Int)) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(plan.gameTitle)
                    .font(.headline)
                    .fontWeight(.bold)
                
                Spacer()
                
                Text("Going")
                    .font(.caption)
                    .fontWeight(.bold)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.green.opacity(0.15))
                    .foregroundStyle(.green)
                    .clipShape(Capsule())
            }
            
            Text(plan.bar.name)
                .font(.subheadline)
                .fontWeight(.semibold)
            
            Text(plan.bar.address)
                .font(.caption)
                .foregroundStyle(.secondary)
            
            Label("\(plan.count) people interested / going", systemImage: "person.3.fill")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundStyle(.green)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }
    
    private func venueCard(_ bar: BarVenue) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(bar.name)
                .font(.headline)
                .fontWeight(.bold)
            
            Text(bar.address)
                .font(.caption)
                .foregroundStyle(.secondary)
            
            FlowTags(tags: bar.tags)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }
}
