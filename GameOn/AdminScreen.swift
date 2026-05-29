import SwiftUI

struct AdminScreen: View {
    @ObservedObject var viewModel: MapViewModel
    @State private var password = ""
    @State private var selectedBusiness: AdminBusinessVenueOverrideSummary?
    
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
                        businessVenueOverridesSection
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
            await viewModel.refreshAdminBusinessVenueOverrides()
        }
        .sheet(item: $selectedBusiness) { business in
            AdminBusinessVenueDetailsSheet(viewModel: viewModel, business: business)
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

    private var businessVenueOverridesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Business Venue Overrides")
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)

                Spacer()

                Button {
                    Task { await viewModel.refreshAdminBusinessVenueOverrides() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.78))
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isLoadingAdminBusinessVenueOverrides)
            }

            if !viewModel.adminBusinessVenueOverrideMessage.isEmpty {
                Text(viewModel.adminBusinessVenueOverrideMessage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }

            if viewModel.isLoadingAdminBusinessVenueOverrides {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading businesses...")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(.white.opacity(0.75))
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 18))
            } else if viewModel.adminBusinessVenueOverrideSummaries.isEmpty {
                Text("No active businesses found.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.75))
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 18))
            } else {
                ForEach(viewModel.adminBusinessVenueOverrideSummaries) { business in
                    adminBusinessCard(business)
                }
            }
        }
    }

    private func adminBusinessCard(_ business: AdminBusinessVenueOverrideSummary) -> some View {
        Button {
            selectedBusiness = business
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(adminBusinessName(business))
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.primary)
                        Text(business.owner_email ?? "Owner email unavailable")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text(business.computed_is_pro ? "Pro" : "Regular")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(business.computed_is_pro ? .yellow : .blue)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background((business.computed_is_pro ? Color.yellow : Color.blue).opacity(0.14))
                        .clipShape(Capsule())
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                    adminBusinessMetric("Active", value: "\(business.active_count)", tint: .green)
                    adminBusinessMetric("Locked", value: "\(business.locked_count)", tint: .orange)
                    adminBusinessMetric("Effective limit", value: business.effective_venue_limit.map(String.init) ?? "Unlimited", tint: .blue)
                    adminBusinessMetric("Override", value: business.admin_active_venue_limit_override.map(String.init) ?? "None", tint: .purple)
                }
            }
            .padding()
            .background(Color.white.opacity(0.95))
            .clipShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .onAppear {
#if DEBUG
            print("[AdminVenueOverrideDebug] card businessId=\(business.business_id.uuidString.lowercased()) active=\(business.active_count) locked=\(business.locked_count) effectiveLimit=\(business.effective_venue_limit.map(String.init) ?? "unlimited") override=\(business.admin_active_venue_limit_override.map(String.init) ?? "nil")")
#endif
        }
    }

    private func adminBusinessMetric(_ title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.headline.weight(.heavy))
                .foregroundStyle(tint)
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(tint.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 13))
    }

    private func adminBusinessName(_ business: AdminBusinessVenueOverrideSummary) -> String {
        let name = business.display_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "Business" : name
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

private struct AdminBusinessVenueDetailsSheet: View {
    @ObservedObject var viewModel: MapViewModel
    let business: AdminBusinessVenueOverrideSummary

    @Environment(\.dismiss) private var dismiss
    @State private var venues: [AdminBusinessVenueOverrideVenue] = []
    @State private var overrideText = ""
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var message = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summaryCard
                    overrideCard
                    venuesCard
                }
                .padding()
            }
            .navigationTitle("Business Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await loadVenues() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading || isSaving)
                }
            }
            .task { await loadVenues() }
            .onAppear {
                overrideText = business.admin_active_venue_limit_override.map(String.init) ?? ""
            }
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(displayName)
                .font(.title3.weight(.bold))
            Text(business.owner_email ?? "Owner email unavailable")
                .font(.caption)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10)], spacing: 10) {
                metric("Active venue count", value: "\(currentBusiness.active_count)", tint: .green)
                metric("Locked venue count", value: "\(currentBusiness.locked_count)", tint: .orange)
                metric("Effective venue limit", value: currentBusiness.effective_venue_limit.map(String.init) ?? "Unlimited", tint: .blue)
                metric("Admin override limit", value: currentBusiness.admin_active_venue_limit_override.map(String.init) ?? "None", tint: .purple)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .onAppear {
#if DEBUG
            print("[AdminVenueOverrideDebug] details businessId=\(business.business_id.uuidString.lowercased()) active=\(currentBusiness.active_count) locked=\(currentBusiness.locked_count) effectiveLimit=\(currentBusiness.effective_venue_limit.map(String.init) ?? "unlimited") override=\(currentBusiness.admin_active_venue_limit_override.map(String.init) ?? "nil")")
#endif
        }
    }

    private var overrideCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Admin override limit")
                .font(.headline.weight(.bold))
            Text("For Free businesses, the effective limit is the override when set, otherwise the business venue limit. Pro businesses remain unlimited.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                TextField("Override limit", text: $overrideText)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)

                Button("Set") {
                    Task { await saveOverride() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving || Int(overrideText.trimmingCharacters(in: .whitespacesAndNewlines)) == nil)

                Button("Clear") {
                    Task { await clearOverride() }
                }
                .buttonStyle(.bordered)
                .disabled(isSaving || currentBusiness.admin_active_venue_limit_override == nil)
            }

            if !message.isEmpty {
                Text(message)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(message.localizedCaseInsensitiveContains("could") ? .red : .secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private var venuesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Approved venues")
                    .font(.headline.weight(.bold))
                Spacer()
                if isLoading {
                    ProgressView()
                }
            }

            if venues.isEmpty && !isLoading {
                Text("No approved venues found for this business.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(venues) { venue in
                    venueRow(venue)
                    if venue.id != venues.last?.id {
                        Divider()
                    }
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private func venueRow(_ venue: AdminBusinessVenueOverrideVenue) -> some View {
        let active = (venue.admin_status ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "active"
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: active ? "checkmark.seal.fill" : "lock.fill")
                .foregroundStyle(active ? .green : .orange)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(venueDisplayName(venue))
                    .font(.subheadline.weight(.semibold))
                Text(venueLocation(venue))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(active ? "Active" : BusinessLimitCopy.planLockedVenueBadge)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(active ? .green : .orange)
            }

            Spacer(minLength: 0)

            Button(active ? "Deactivate" : "Activate") {
                Task { await setVenue(venue, active: !active) }
            }
            .buttonStyle(.bordered)
            .disabled(isSaving || (!active && !currentBusiness.computed_is_pro && currentBusiness.active_count >= (currentBusiness.effective_venue_limit ?? 0)))
        }
        .padding(.vertical, 6)
        .opacity(active ? 1 : 0.72)
    }

    private func metric(_ title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.headline.weight(.heavy))
                .foregroundStyle(tint)
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(tint.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 13))
    }

    private func loadVenues() async {
        await MainActor.run {
            isLoading = true
            message = ""
        }
        let loaded = await viewModel.loadAdminBusinessOverrideVenues(businessId: business.business_id)
        await MainActor.run {
            venues = loaded
            isLoading = false
        }
    }

    private func saveOverride() async {
        guard let value = Int(overrideText.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        await MainActor.run {
            isSaving = true
            message = ""
        }
        let saved = await viewModel.setAdminBusinessActiveVenueLimitOverride(businessId: business.business_id, override: value)
        await MainActor.run {
            isSaving = false
            message = saved ? "Override saved." : "Could not save override."
        }
        if saved { await loadVenues() }
    }

    private func clearOverride() async {
        await MainActor.run {
            isSaving = true
            message = ""
        }
        let saved = await viewModel.clearAdminBusinessActiveVenueLimitOverride(businessId: business.business_id)
        await MainActor.run {
            isSaving = false
            overrideText = ""
            message = saved ? "Override cleared." : "Could not clear override."
        }
        if saved { await loadVenues() }
    }

    private func setVenue(_ venue: AdminBusinessVenueOverrideVenue, active: Bool) async {
        await MainActor.run {
            isSaving = true
            message = ""
        }
        let saved = await viewModel.setAdminBusinessVenueActivation(
            businessId: business.business_id,
            venueId: venue.venue_id,
            active: active
        )
        await MainActor.run {
            isSaving = false
            message = saved ? "Venue updated." : "Could not update venue."
        }
        if saved { await loadVenues() }
    }

    private var displayName: String {
        let value = currentBusiness.display_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "Business" : value
    }

    private var currentBusiness: AdminBusinessVenueOverrideSummary {
        viewModel.adminBusinessVenueOverrideSummaries.first { $0.business_id == business.business_id } ?? business
    }

    private func venueDisplayName(_ venue: AdminBusinessVenueOverrideVenue) -> String {
        let value = venue.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "Venue" : value
    }

    private func venueLocation(_ venue: AdminBusinessVenueOverrideVenue) -> String {
        let city = venue.city?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let state = venue.state?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let location = [city, state].filter { !$0.isEmpty }.joined(separator: ", ")
        return location.isEmpty ? "Location unavailable" : location
    }
}
