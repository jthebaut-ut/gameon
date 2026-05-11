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
                        claimsList
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 110)
            }
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
