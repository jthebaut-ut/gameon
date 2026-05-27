import SwiftUI

struct AdminScreen: View {
    @ObservedObject var viewModel: MapViewModel
    @State private var password = ""
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.94)
                .ignoresSafeArea()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Admin")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .padding(.top, 22)
                    
                    Text("Review venue claims before they appear publicly.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                    
                    if !viewModel.isAdminLoggedIn {
                        adminLoginCard
                    } else {
                        liveOperationsMetricsCard
                        claimsList
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 110)
            }
        }
        .task(id: viewModel.isAdminLoggedIn) {
            guard viewModel.isAdminLoggedIn else { return }
            await viewModel.refreshLiveOperationsPresenceMetrics()
        }
    }
    
    private var adminLoginCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Admin Login")
                .font(.headline)
                .fontWeight(.bold)
            
            TextField("Admin email", text: $viewModel.adminEmail)
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
                .padding()
                .background(Color.gray.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 16))
            
            SecureField("Password", text: $password)
                .padding()
                .background(Color.gray.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 16))
            
            Button {
                viewModel.adminDashboardLoginTapped()
            } label: {
                Text("Login as Admin")
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.black)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
        }
        .padding()
        .background(Color.white.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 22))
    }
    
    private var claimsList: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Venue Claims")
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
                
                Spacer()
                
                Button("Log Out") {
                    viewModel.adminDashboardLogoutTapped()
                }
                .font(.caption)
                .fontWeight(.bold)
                .foregroundStyle(.red)
            }
            
            if viewModel.venueClaims.isEmpty {
                Text("No venue claims yet.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.75))
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 18))
            } else {
                ForEach(viewModel.venueClaims) { claim in
                    claimCard(claim)
                }
            }
        }
    }

    private var liveOperationsMetricsCard: some View {
        let metrics = viewModel.liveOperationsPresenceMetrics
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Live Operations", systemImage: "dot.radiowaves.left.and.right")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    Task { await viewModel.refreshLiveOperationsPresenceMetrics() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.78))
                }
                .buttonStyle(.plain)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 138), spacing: 10)], spacing: 10) {
                liveMetricTile("Users online now", value: metrics.users_online_now, tint: .green)
                liveMetricTile("Businesses online now", value: metrics.businesses_online_now, tint: .mint)
                liveMetricTile("Active today", value: metrics.active_users_today, tint: .blue)
                liveMetricTile("Active this week", value: metrics.active_users_this_week, tint: .purple)
                liveMetricTile("Active this month", value: metrics.active_users_this_month, tint: .orange)
            }
        }
        .padding()
        .background(Color.white.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private func liveMetricTile(_ title: String, value: Int, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(value)")
                .font(.title2.weight(.heavy))
                .foregroundStyle(.white)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(tint.opacity(0.18))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(tint.opacity(0.28), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
    
    private func claimCard(_ claim: VenueClaim) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(claim.venueName)
                    .font(.headline)
                    .fontWeight(.bold)
                
                Spacer()
                
                Text(claim.status.rawValue)
                    .font(.caption)
                    .fontWeight(.bold)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(statusColor(claim.status).opacity(0.15))
                    .foregroundStyle(statusColor(claim.status))
                    .clipShape(Capsule())
            }
            
            Text(claim.address)
                .font(.caption)
                .foregroundStyle(.secondary)
            
            Text("Email: \(claim.businessEmail)")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            Text("Phone: \(claim.phone)")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            Text("Website: \(claim.website)")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            Text("Primary sport: \(claim.primarySport)")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            if !claim.proofNote.isEmpty {
                Text("Proof: \(claim.proofNote)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            if claim.status == .pending {
                HStack {
                    Button {
                        viewModel.approveVenueClaim(claim)
                    } label: {
                        Text("Approve")
                            .fontWeight(.bold)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.green)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    
                    Button {
                        viewModel.rejectVenueClaim(claim)
                    } label: {
                        Text("Reject")
                            .fontWeight(.bold)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.red)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
        }
        .padding()
        .background(Color.white.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }
    
    private func statusColor(_ status: VenueClaimStatus) -> Color {
        switch status {
        case .pending: return .orange
        case .approved: return .green
        case .rejected: return .red
        }
    }
}
