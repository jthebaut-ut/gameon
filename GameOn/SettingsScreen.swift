import SwiftUI
import PhotosUI

/// Account tab: end-user and venue-owner auth, profile, notifications, Apple Calendar sync, and entry to venue dashboard flows.
struct SettingsScreen: View {
    @ObservedObject var viewModel: MapViewModel
    
    @State private var selectedSettingsMode: SettingsMode = .general

    enum SettingsMode {
        case general
        case user
        case venue
    }
    
    @State private var email = ""
    @State private var password = ""
    @State private var venuePassword = ""
    @State private var showRegisterMode = false
    @State private var showVenueDashboard = false
    @State private var showVenueRegisterMode = false
    @State private var selectedClaimCoverPhoto: PhotosPickerItem?
    @State private var selectedClaimMenuPhoto: PhotosPickerItem?
    @State private var isUploadingClaimCoverPhoto = false
    @State private var isUploadingClaimMenuPhoto = false
    @State private var claimPhotoMessage = ""
    @State private var showProfileScreen = false
    
    
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black.opacity(0.92), Color.gray.opacity(0.65)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    SettingsHeader()
                    SettingsModeSegmentedPicker(selection: $selectedSettingsMode)

                    Group {
                        switch selectedSettingsMode {
                        case .general:
                            SettingsGeneralSection(viewModel: viewModel)
                                .transition(.opacity)

                        case .user:
                            SettingsUserSection(
                                viewModel: viewModel,
                                email: $email,
                                password: $password,
                                showRegisterMode: $showRegisterMode,
                                showProfileScreen: $showProfileScreen
                            )
                                .transition(.opacity.combined(with: .move(edge: .leading)))

                        case .venue:
                            SettingsVenueSection(
                                viewModel: viewModel,
                                venuePassword: $venuePassword,
                                showVenueRegisterMode: $showVenueRegisterMode,
                                selectedClaimCoverPhoto: $selectedClaimCoverPhoto,
                                selectedClaimMenuPhoto: $selectedClaimMenuPhoto,
                                claimPhotoMessage: claimPhotoMessage,
                                showVenueDashboard: $showVenueDashboard
                            )
                                .transition(.opacity.combined(with: .move(edge: .trailing)))
                        }
                    }
                    .animation(.spring(response: 0.35, dampingFraction: 0.85), value: selectedSettingsMode)

                    Spacer()
                }
                .padding(.horizontal)
                .padding(.bottom, 110)
            }
        }
        .sheet(isPresented: $showVenueDashboard) {
            VenueOwnerDashboardView(viewModel: viewModel)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .onAppear {
            selectedSettingsMode = .general
        }
        .onChange(of: selectedClaimCoverPhoto) { _, newItem in
            guard let newItem else { return }

            Task {
                isUploadingClaimCoverPhoto = true
                claimPhotoMessage = "Uploading bar photo..."
                let oldURL = viewModel.venueCoverPhotoURL

                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let url = await viewModel.uploadVenuePhoto(data: data, fileName: "claim-cover.jpg") {
                    viewModel.venueCoverPhotoURL = url
                    claimPhotoMessage = "Bar photo uploaded."
                    // Safe deletion: only for pre-approval claim drafting.
                    if !viewModel.venueIsApproved {
                        await viewModel.deleteVenuePhotoIfPossible(previousPhotoURL: oldURL)
                    }
                } else {
                    claimPhotoMessage = "Unable to upload bar photo."
                }

                isUploadingClaimCoverPhoto = false
            }
        }
        .onChange(of: selectedClaimMenuPhoto) { _, newItem in
            guard let newItem else { return }

            Task {
                isUploadingClaimMenuPhoto = true
                claimPhotoMessage = "Uploading menu photo..."
                let oldURL = viewModel.venueMenuPhotoURL

                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let url = await viewModel.uploadVenuePhoto(data: data, fileName: "claim-menu.jpg") {
                    viewModel.venueMenuPhotoURL = url
                    claimPhotoMessage = "Menu photo uploaded."
                    // Safe deletion: only for pre-approval claim drafting.
                    if !viewModel.venueIsApproved {
                        await viewModel.deleteVenuePhotoIfPossible(previousPhotoURL: oldURL)
                    }
                } else {
                    claimPhotoMessage = "Unable to upload menu photo."
                }

                isUploadingClaimMenuPhoto = false
            }
        }
    }
}

// MARK: - Header & mode picker

private struct SettingsHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Settings")
                .font(.largeTitle)
                .fontWeight(.bold)
                .foregroundStyle(.white)
            
            Text("Manage your account and game time display.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.75))
        }
        .padding(.top, 22)
    }
}

private struct SettingsModeSegmentedPicker: View {
    @Binding var selection: SettingsScreen.SettingsMode

    var body: some View {
        Picker("", selection: $selection) {
            Text("General").tag(SettingsScreen.SettingsMode.general)
            Text("User").tag(SettingsScreen.SettingsMode.user)
            Text("Venue").tag(SettingsScreen.SettingsMode.venue)
        }
        .pickerStyle(.segmented)
        .padding(4)
        .background(Color.white.opacity(0.20))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Liquid Glass building blocks (Settings-only)

private struct SettingsSectionHeader: View {
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.70))
            }
        }
        .padding(.top, 6)
    }
}

private struct SettingsGlassCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .background(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: Color.black.opacity(0.20), radius: 16, x: 0, y: 10)
    }
}

private struct SettingsRowButton: View {
    let icon: String
    let title: String
    let subtitle: String?
    var tint: Color = .primary
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint)
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.55)
    }
}

// MARK: - General tab

private struct SettingsGeneralSection: View {
    @ObservedObject var viewModel: MapViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSectionHeader(
                title: "General",
                subtitle: "Preferences shared across your account modes."
            )

            SettingsGlassCard {
                VStack(alignment: .leading, spacing: 14) {
                    SettingsTimeZoneCard(viewModel: viewModel)
                    Divider().opacity(0.25)
                    SettingsGameNotificationsCard(viewModel: viewModel)
                }
            }

            SettingsGlassCard {
                SettingsCalendarDisplayCard(viewModel: viewModel)
            }

            SettingsGlassCard {
                SettingsReportedCommentsAdminCard(viewModel: viewModel)
            }
        }
    }
}

private struct SettingsTimeZoneCard: View {
    @ObservedObject var viewModel: MapViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Game Time Zone")
                .font(.subheadline)
                .fontWeight(.semibold)

            Text("Choose how game times should appear.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Time Zone", selection: $viewModel.selectedTimeZone) {
                ForEach(TimeZoneOption.allCases) { option in
                    Text("\(option.rawValue) (\(option.abbreviation))")
                        .tag(option)
                }
            }
            .pickerStyle(.menu)
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

private struct SettingsCalendarDisplayCard: View {
    @ObservedObject var viewModel: MapViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Calendar Display")
                .font(.subheadline)
                .fontWeight(.semibold)

            Text("Choose how green calendar dots are shown.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Only show games in visible map area",
                   isOn: $viewModel.calendarUsesVisibleMapRegionOnly)
                .font(.subheadline)
                .fontWeight(.semibold)

            Text(viewModel.calendarUsesVisibleMapRegionOnly
                 ? "Matches games to the current map region. Zoom out to discover more."
                 : "Shows all available games regardless of map view.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct SettingsReportedCommentsAdminCard: View {
    @ObservedObject var viewModel: MapViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reported Comments")
                .font(.headline)
                .fontWeight(.bold)

            Button {
                Task {
                    await viewModel.loadReportedComments()
                }
            } label: {
                Text("Refresh Reports")
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.black)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }

            if viewModel.reportedCommentDisplays.isEmpty {
                Text("No reported comments.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.reportedCommentDisplays) { report in
                    VStack(alignment: .leading, spacing: 12) {

                        HStack(alignment: .top, spacing: 12) {

                            if let url = URL(string: report.commenterAvatarURL),
                               !report.commenterAvatarURL.isEmpty {

                                AsyncImage(url: url) { image in
                                    image
                                        .resizable()
                                        .scaledToFill()
                                } placeholder: {
                                    Circle()
                                        .fill(Color.gray.opacity(0.20))
                                }
                                .frame(width: 44, height: 44)
                                .clipShape(Circle())

                            } else {

                                Circle()
                                    .fill(Color.orange.opacity(0.15))
                                    .frame(width: 44, height: 44)
                                    .overlay {
                                        Text(String(report.commenterName.prefix(1)).uppercased())
                                            .fontWeight(.bold)
                                            .foregroundStyle(.orange)
                                    }
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text(report.commenterName)
                                    .font(.headline)
                                    .fontWeight(.bold)

                                Text("“\(report.commentText)”")
                                    .font(.subheadline)

                                Text("\(report.venueName) • \(report.eventTitle)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Text("Reported: \(formattedReportDate(report.reportedAt))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Text("Reported by: \(report.reporterName)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                
                                Button {
                                    Task {
                                        await viewModel.deleteReportedComment(report)
                                        await viewModel.loadReportedComments()
                                    }
                                } label: {
                                    Label("Delete Comment", systemImage: "xmark.circle.fill")
                                        .font(.caption)
                                        .fontWeight(.bold)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .background(Color.red.opacity(0.14))
                                        .foregroundStyle(.red)
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                    
                                    Button {
                                        Task {
                                            await viewModel.dismissCommentReport(report)
                                        }
                                    } label: {
                                        Label("Dismiss Report", systemImage: "checkmark.circle.fill")
                                            .font(.caption)
                                            .fontWeight(.bold)
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 10)
                                            .background(Color.green.opacity(0.14))
                                            .foregroundStyle(.green)
                                            .clipShape(RoundedRectangle(cornerRadius: 12))
                                    }
                                }
                            }
                        }
                    }
                    .padding()
                    .background(Color.red.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }
            }
        }
        .padding()
        .background(Color.white.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 22))
    }

    private func formattedReportDate(_ rawDate: String) -> String {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]

        guard let date = isoFormatter.date(from: rawDate) else {
            return rawDate
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd h:mm a 'MT'"
        formatter.timeZone = TimeZone(identifier: "America/Denver")

        return formatter.string(from: date)
    }
}

// MARK: - User tab

private struct SettingsUserSection: View {
    @ObservedObject var viewModel: MapViewModel
    @Binding var email: String
    @Binding var password: String
    @Binding var showRegisterMode: Bool
    @Binding var showProfileScreen: Bool
    @State private var selectedAvatarItem: PhotosPickerItem?
    @State private var isUploadingAvatar: Bool = false
    @State private var avatarMessage: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSectionHeader(
                title: "User",
                subtitle: viewModel.isLoggedIn ? "Manage your profile and account security." : "Create an account to sync your profile and activity."
            )
            if viewModel.isLoggedIn {
                userProfileHubCard
                SettingsGlassCard { SettingsSavedGamesCard() }
            }

            SettingsGlassCard {
                SettingsAccountCard(
                    viewModel: viewModel,
                    email: $email,
                    password: $password,
                    showRegisterMode: $showRegisterMode
                )
            }

            SettingsGlassCard {
                SettingsFanPasswordResetCard(viewModel: viewModel, loginEmail: $email)
            }

            if viewModel.isLoggedIn {
                SettingsGlassCard {
                    SettingsFanAccountSecurityCard(viewModel: viewModel)
                }
            }
        }
        .onChange(of: selectedAvatarItem) { _, item in
            guard let item else { return }
            Task {
                isUploadingAvatar = true
                avatarMessage = "Uploading avatar..."
                let oldURL = viewModel.currentUserAvatarURL
                do {
                    guard let data = try? await item.loadTransferable(type: Data.self) else {
                        avatarMessage = "Unable to read photo."
                        isUploadingAvatar = false
                        return
                    }
                    guard let newURL = await viewModel.uploadUserAvatar(data: data, fileName: "avatar.jpg") else {
                        avatarMessage = "Unable to upload avatar."
                        isUploadingAvatar = false
                        return
                    }
                    let display = resolvedDisplayName
                    await viewModel.saveUserProfile(displayName: display, avatarURL: newURL)
                    await viewModel.deleteUserAvatarIfPossible(previousAvatarURL: oldURL)
                    avatarMessage = "Avatar updated."
                } catch {
                    avatarMessage = "Unable to upload avatar."
                }
                isUploadingAvatar = false
            }
        }
    }

    private var resolvedDisplayName: String {
        let current = viewModel.currentUserDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty { return current }
        // Default display name from email local-part (e.g., peter@email.com -> Peter)
        let email = viewModel.currentUserEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let local = email.split(separator: "@").first.map(String.init) ?? ""
        guard !local.isEmpty else { return "" }
        return local.prefix(1).uppercased() + local.dropFirst()
    }

    private var initials: String {
        let name = resolvedDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            let parts = name.split(separator: " ").filter { !$0.isEmpty }
            if parts.count >= 2 {
                return "\(parts[0].prefix(1))\(parts[1].prefix(1))".uppercased()
            }
            return "\(name.prefix(2))".uppercased()
        }
        let email = viewModel.currentUserEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let local = email.split(separator: "@").first.map(String.init) ?? ""
        return local.isEmpty ? "U" : "\(local.prefix(2))".uppercased()
    }

    private var userProfileHubCard: some View {
        SettingsGlassCard {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.black.opacity(0.06))
                    if let url = URL(string: viewModel.currentUserAvatarURL), !viewModel.currentUserAvatarURL.isEmpty {
                        AsyncImage(url: url) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            ProgressView()
                        }
                    } else {
                        Text(initials)
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.primary)
                    }
                }
                .frame(width: 52, height: 52)
                .clipShape(Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(resolvedDisplayName.isEmpty ? "My profile" : resolvedDisplayName)
                        .font(.headline.weight(.bold))
                    Text(viewModel.currentUserEmail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Button {
                    showProfileScreen = true
                } label: {
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.secondary)
                }
            }

            PhotosPicker(selection: $selectedAvatarItem, matching: .images) {
                HStack {
                    if isUploadingAvatar {
                        ProgressView().tint(.primary)
                    }
                    Text(isUploadingAvatar ? "Uploading..." : "Update avatar")
                        .fontWeight(.bold)
                    Spacer()
                }
                .padding()
                .background(Color.black.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .disabled(isUploadingAvatar)

            if !avatarMessage.isEmpty {
                Text(avatarMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Account security (fan)

private struct SettingsFanAccountSecurityCard: View {
    @ObservedObject var viewModel: MapViewModel
    @State private var isShowingDeleteSheet = false
    @State private var deleteConfirmationText = ""
    @State private var isDeleting = false
    @State private var deletionErrorMessage = ""
    @State private var deletionSuccessMessage = ""

    private var trimmedConfirmation: String {
        deleteConfirmationText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var deletionEnabled: Bool {
        let email = viewModel.currentUserEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else { return false }
        return trimmedConfirmation.caseInsensitiveCompare("DELETE") == .orderedSame ||
            trimmedConfirmation.caseInsensitiveCompare(email) == .orderedSame
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Account security")
                .font(.headline)
                .fontWeight(.bold)

            Text("Manage sensitive account actions. For permanent deletion, you’ll be asked to confirm before anything is removed.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                deletionErrorMessage = ""
                deletionSuccessMessage = ""
                deleteConfirmationText = ""
                isShowingDeleteSheet = true
            } label: {
                Label("Delete account permanently", systemImage: "trash")
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.red.opacity(0.12))
                    .foregroundStyle(.red)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }

            if !deletionSuccessMessage.isEmpty {
                Text(deletionSuccessMessage)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.green)
            }

            if !deletionErrorMessage.isEmpty {
                Text(deletionErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .sheet(isPresented: $isShowingDeleteSheet) {
            deleteAccountSheet
        }
    }

    private var deleteAccountSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Delete account permanently")
                .font(.title2)
                .fontWeight(.bold)

            Text("This will permanently delete your fan account and remove your profile, favorites, and activity. This cannot be undone.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                Text("To confirm, type your email or the word DELETE:")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                TextField("Type email or DELETE", text: $deleteConfirmationText)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .padding()
                    .background(Color.gray.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                HStack(spacing: 10) {
                    Button {
                        isShowingDeleteSheet = false
                    } label: {
                        Text("Cancel")
                            .fontWeight(.bold)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.gray.opacity(0.14))
                            .foregroundStyle(.primary)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    .disabled(isDeleting)

                    Button {
                        Task {
                            isDeleting = true
                            deletionErrorMessage = ""
                            deletionSuccessMessage = ""

                            do {
                                try await viewModel.requestPermanentAccountDeletion()
                                deletionSuccessMessage = "Account deleted. You’ve been signed out."
                                isShowingDeleteSheet = false
                            } catch {
                                deletionErrorMessage = error.localizedDescription
                            }

                            isDeleting = false
                        }
                    } label: {
                        HStack {
                            if isDeleting {
                                ProgressView()
                                    .tint(.red)
                            }
                            Text(isDeleting ? "Deleting..." : "Delete permanently")
                                .fontWeight(.bold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.red.opacity(0.12))
                        .foregroundStyle(.red)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    .disabled(!deletionEnabled || isDeleting)
                }
            }

            Spacer()
        }
        .padding()
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private struct SettingsAccountCard: View {
    @ObservedObject var viewModel: MapViewModel
    @Binding var email: String
    @Binding var password: String
    @Binding var showRegisterMode: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(showRegisterMode ? "Register" : "Login")
                .font(.headline)
                .fontWeight(.bold)
            
            if viewModel.isLoggedIn {
                HStack {
                    Image(systemName: "person.circle.fill")
                        .font(.title)
                    
                    VStack(alignment: .leading) {
                        Text("Signed in")
                            .fontWeight(.bold)
                        Text(viewModel.currentUserEmail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                }
                
                Button {
                    Task {
                        await viewModel.logoutUser()
                        email = ""
                        password = ""
                    }
                } label: {
                    Text("Log Out")
                        .fontWeight(.bold)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.red.opacity(0.12))
                        .foregroundStyle(.red)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
            } else {
                TextField("Email", text: $email)
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
                    Task {
                        if showRegisterMode {
                            await viewModel.registerUser(email: email, password: password)
                        } else {
                            await viewModel.loginUser(email: email, password: password)
                        }
                    }
                } label: {
                    Text(showRegisterMode ? "Create Account" : "Login")
                        .fontWeight(.bold)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.black)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }


                
                if !viewModel.authErrorMessage.isEmpty {
                    Text(viewModel.authErrorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                
                Button {
                    showRegisterMode.toggle()
                } label: {
                    Text(showRegisterMode ? "Already have an account? Login" : "New user? Register")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(.blue)
                }
            }
        }
    }
}

// MARK: - Fan password reset

/// Password recovery email for the fan account; reuses the login email field when signed out.
private struct SettingsFanPasswordResetCard: View {
    @ObservedObject var viewModel: MapViewModel
    @Binding var loginEmail: String
    @State private var isSending = false

    private var emailForReset: String {
        if viewModel.isLoggedIn {
            return viewModel.currentUserEmail
        }
        return loginEmail.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Reset password")
                .font(.headline)
                .fontWeight(.bold)

            Text("We’ll email you a secure link to choose a new password. Use the same email as your fan account.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if viewModel.isLoggedIn {
                HStack(spacing: 8) {
                    Image(systemName: "envelope.fill")
                        .foregroundStyle(.secondary)
                    Text(viewModel.currentUserEmail)
                        .font(.subheadline)
                        .fontWeight(.medium)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.gray.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 16))
            } else {
                TextField("Email for password reset", text: $loginEmail)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .padding()
                    .background(Color.gray.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }

            Button {
                Task {
                    isSending = true
                    await viewModel.sendPasswordResetEmail(emailForReset, accountKind: .fan)
                    isSending = false
                }
            } label: {
                HStack {
                    if isSending {
                        ProgressView()
                            .tint(.white)
                    }
                    Text("Send reset link")
                        .fontWeight(.bold)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.black.opacity(isSending ? 0.45 : 1))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .disabled(isSending)

            if !viewModel.userPasswordResetMessage.isEmpty {
                Text(viewModel.userPasswordResetMessage)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.green)
            }

            if !viewModel.userPasswordResetError.isEmpty {
                Text(viewModel.userPasswordResetError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}

// MARK: - Venue owner password reset

/// Password recovery for the venue-owner Supabase account (same Auth table as fans; uses the venue business email field when present).
private struct SettingsVenuePasswordResetCard: View {
    @ObservedObject var viewModel: MapViewModel
    @State private var isSending = false
    @State private var emailIfMissing = ""

    private var emailForReset: String {
        let fromProfile = viewModel.venueOwnerEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fromProfile.isEmpty { return fromProfile }
        return emailIfMissing.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Reset venue password")
                .font(.headline)
                .fontWeight(.bold)

            Text("We’ll email a link to reset the password for your venue owner login.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if viewModel.isVenueOwnerLoggedIn {
                HStack(spacing: 8) {
                    Image(systemName: "envelope.fill")
                        .foregroundStyle(.secondary)
                    Text(viewModel.venueOwnerEmail)
                        .font(.subheadline)
                        .fontWeight(.medium)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.gray.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 16))
            } else if viewModel.venueOwnerEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                TextField("Venue owner email for reset", text: $emailIfMissing)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .padding()
                    .background(Color.gray.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            } else {
                Text("Uses the business email you entered above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                Task {
                    isSending = true
                    await viewModel.sendPasswordResetEmail(emailForReset, accountKind: .venueOwner)
                    isSending = false
                }
            } label: {
                HStack {
                    if isSending {
                        ProgressView()
                            .tint(.white)
                    }
                    Text("Send reset link")
                        .fontWeight(.bold)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.black.opacity(isSending ? 0.45 : 1))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .disabled(isSending)

            if !viewModel.venuePasswordResetMessage.isEmpty {
                Text(viewModel.venuePasswordResetMessage)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.green)
            }

            if !viewModel.venuePasswordResetError.isEmpty {
                Text(viewModel.venuePasswordResetError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .background(Color.white.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 22))
    }
}

private struct SettingsGameNotificationsCard: View {
    @ObservedObject var viewModel: MapViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Game Notifications")
                .font(.title2)
                .fontWeight(.bold)

            Toggle("Notify me before games I’m going to", isOn: $viewModel.notifyBeforeGame)
                .fontWeight(.semibold)

            

            if viewModel.notifyBeforeGame {
                Picker("Remind me before", selection: $viewModel.reminderMinutesBefore) {
                    Text("15 minutes before").tag(15)
                    Text("30 minutes before").tag(30)
                    Text("1 hour before").tag(60)
                    Text("2 hours before").tag(120)
                    Text("3 hours before").tag(180)
                    Text("1 day before").tag(1440)
                }
                .pickerStyle(.menu)

                Toggle("Repeat reminder until game starts", isOn: $viewModel.repeatGameReminder)
                    .fontWeight(.semibold)

                if viewModel.repeatGameReminder {
                    Picker("Repeat every", selection: $viewModel.repeatEveryMinutes) {
                        Text("Every 15 minutes").tag(15)
                        Text("Every 30 minutes").tag(30)
                        Text("Every hour").tag(60)
                        Text("Every 2 hours").tag(120)
                    }
                    .pickerStyle(.menu)
                }
            }
            
            Toggle("Sync games I’m going to with Apple Calendar", isOn: $viewModel.syncGoingGamesToAppleCalendar)
                .fontWeight(.semibold)
            
            Text("When enabled, games marked as Going will be added to your Apple Calendar.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color.white.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}

private struct SettingsSavedGamesCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Saved Games")
                .font(.headline)
                .fontWeight(.bold)

            Text("Manage reminders and saved games for your account.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Saved games are available only when logged in as a user.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color.white.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 22))
    }
}

private struct SettingsProfileButton: View {
    @ObservedObject var viewModel: MapViewModel
    @Binding var showProfileScreen: Bool

    var body: some View {
        Button {
            showProfileScreen = true
        } label: {
            HStack {
                SettingsAccountProfileImage(avatarURLString: viewModel.currentUserAvatarURL)

                VStack(alignment: .leading, spacing: 4) {
                    Text("My Profile")
                        .fontWeight(.bold)
                        .foregroundStyle(.primary)

                    Text("Change display name and profile photo")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(Color.white.opacity(0.95))
            .clipShape(RoundedRectangle(cornerRadius: 22))
        }
        .sheet(isPresented: $showProfileScreen) {
            UserProfileScreen(viewModel: viewModel) {
                showProfileScreen = false
            }
        }
    }
}

private struct SettingsAccountProfileImage: View {
    let avatarURLString: String

    var body: some View {
        Group {
            if let url = URL(string: avatarURLString),
               !avatarURLString.isEmpty {
                AsyncImage(url: url) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    ProgressView()
                }
            } else {
                Image(systemName: "person.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.green)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(Circle())
    }
}

// MARK: - Venue tab

private struct SettingsVenueSection: View {
    @ObservedObject var viewModel: MapViewModel
    @Binding var venuePassword: String
    @Binding var showVenueRegisterMode: Bool
    @Binding var selectedClaimCoverPhoto: PhotosPickerItem?
    @Binding var selectedClaimMenuPhoto: PhotosPickerItem?
    let claimPhotoMessage: String
    @Binding var showVenueDashboard: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSectionHeader(
                title: "Venue",
                subtitle: viewModel.isVenueOwnerLoggedIn
                    ? "Manage your venue profile, media, and tools."
                    : "Create or sign in to your venue owner account."
            )

            SettingsGlassCard {
                SettingsVenueOwnerCard(
                    viewModel: viewModel,
                    venuePassword: $venuePassword,
                    showVenueRegisterMode: $showVenueRegisterMode,
                    selectedClaimCoverPhoto: $selectedClaimCoverPhoto,
                    selectedClaimMenuPhoto: $selectedClaimMenuPhoto,
                    claimPhotoMessage: claimPhotoMessage,
                    showVenueDashboard: $showVenueDashboard
                )
            }

            if viewModel.isVenueOwnerLoggedIn {
                SettingsGlassCard {
                    SettingsVenuePasswordResetCard(viewModel: viewModel)
                }

                SettingsGlassCard {
                    venueToolsCard
                }

                SettingsGlassCard {
                    statisticsCard
                }

                SettingsGlassCard {
                    SettingsVenueOwnerDangerZoneCard(viewModel: viewModel)
                }
            } else {
                SettingsGlassCard {
                    SettingsVenuePasswordResetCard(viewModel: viewModel)
                }
            }
        }
    }

    private var venueToolsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Venue tools")
                .font(.headline.weight(.bold))

            Text("Quick access to venue management tools. More controls will appear here over time.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                SettingsRowButton(
                    icon: "plus.circle.fill",
                    title: "Add game",
                    subtitle: "Create a new game listing for your venue.",
                    tint: .primary,
                    action: { showVenueDashboard = true }
                )
                Divider().opacity(0.25)
                SettingsRowButton(
                    icon: "list.bullet.rectangle",
                    title: "Manage games",
                    subtitle: "Edit or remove upcoming venue games.",
                    tint: .primary,
                    action: { showVenueDashboard = true }
                )
                Divider().opacity(0.25)
                SettingsRowButton(
                    icon: "flag.fill",
                    title: "Flagged comments",
                    subtitle: "Review reported content and moderation signals.",
                    tint: .primary,
                    isEnabled: false,
                    action: {}
                )
            }
        }
    }

    private var statisticsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 16, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                Text("Statistics coming soon")
                    .font(.headline.weight(.bold))
                Spacer()
                Text("Soon")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.gray.opacity(0.14))
                    .foregroundStyle(.secondary)
                    .clipShape(Capsule())
            }
            Text("We’ll add insights like profile views, game interest, and photo performance once moderation and stability are fully deployed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct SettingsVenueOwnerDangerZoneCard: View {
    @ObservedObject var viewModel: MapViewModel
    @State private var isShowingDeleteSheet = false
    @State private var confirmationText = ""
    @State private var isDeleting = false
    @State private var errorMessage = ""
    @State private var successMessage = ""

    private var trimmedConfirmation: String {
        confirmationText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var deletionEnabled: Bool {
        let email = viewModel.venueOwnerEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else { return false }
        return trimmedConfirmation.caseInsensitiveCompare("DELETE") == .orderedSame ||
            trimmedConfirmation.caseInsensitiveCompare(email) == .orderedSame
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Danger zone")
                .font(.headline)
                .fontWeight(.bold)

            Text("Deleting your venue owner account permanently removes your claims, listings, and venue photos. Your venue pin will remain, but it will no longer be linked to an owner.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                errorMessage = ""
                successMessage = ""
                confirmationText = ""
                isShowingDeleteSheet = true
            } label: {
                Label("Delete venue owner account permanently", systemImage: "trash")
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.red.opacity(0.12))
                    .foregroundStyle(.red)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }

            if !successMessage.isEmpty {
                Text(successMessage)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.green)
            }

            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .sheet(isPresented: $isShowingDeleteSheet) {
            deleteSheet
        }
    }

    private var deleteSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Delete venue owner account permanently")
                .font(.title2)
                .fontWeight(.bold)

            Text("This cannot be undone. Your venue owner access will be removed and your published listings and uploaded photos will be deleted. The venue pin will remain on the map without an owner.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("To confirm, type your venue owner email or the word DELETE:")
                .font(.subheadline)
                .fontWeight(.semibold)

            TextField("Type email or DELETE", text: $confirmationText)
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
                .padding()
                .background(Color.gray.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 16))

            HStack(spacing: 10) {
                Button {
                    isShowingDeleteSheet = false
                } label: {
                    Text("Cancel")
                        .fontWeight(.bold)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.gray.opacity(0.14))
                        .foregroundStyle(.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                .disabled(isDeleting)

                Button {
                    Task {
                        isDeleting = true
                        errorMessage = ""
                        successMessage = ""

                        do {
                            try await viewModel.requestPermanentVenueOwnerAccountDeletion()
                            successMessage = "Venue owner account deleted. You’ve been signed out."
                            isShowingDeleteSheet = false
                        } catch {
                            errorMessage = error.localizedDescription
                        }

                        isDeleting = false
                    }
                } label: {
                    HStack {
                        if isDeleting {
                            ProgressView()
                                .tint(.red)
                        }
                        Text(isDeleting ? "Deleting..." : "Delete permanently")
                            .fontWeight(.bold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.red.opacity(0.12))
                    .foregroundStyle(.red)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                .disabled(!deletionEnabled || isDeleting)
            }

            Spacer()
        }
        .padding()
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private struct SettingsVenueOwnerCard: View {
    @ObservedObject var viewModel: MapViewModel
    @Binding var venuePassword: String
    @Binding var showVenueRegisterMode: Bool
    @Binding var selectedClaimCoverPhoto: PhotosPickerItem?
    @Binding var selectedClaimMenuPhoto: PhotosPickerItem?
    let claimPhotoMessage: String
    @Binding var showVenueDashboard: Bool
    @State private var claimValidationMessage: String = ""
    @State private var photoReviewStatus: String = ""
    @State private var pendingCoverUploaded: Bool = false
    @State private var pendingMenuUploaded: Bool = false

    private func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func refreshVenuePhotoReviewState() {
        Task {
            guard viewModel.isVenueOwnerLoggedIn else { return }
            guard let profile = await viewModel.loadVenueProfile() else { return }
            await MainActor.run {
                let status = (profile.photo_review_status ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                photoReviewStatus = status
                pendingCoverUploaded = !(profile.pending_cover_photo_url ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                pendingMenuUploaded = !(profile.pending_menu_photo_url ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

                // Always show currently public/approved photos in the UI.
                if let cover = profile.cover_photo_url {
                    viewModel.venueCoverPhotoURL = cover
                }
                if let menu = profile.menu_photo_url {
                    viewModel.venueMenuPhotoURL = menu
                }
            }
        }
    }

    private var isClaimReadyToSubmit: Bool {
        trimmed(viewModel.ownerVenueName).isEmpty == false
            && trimmed(viewModel.ownerVenueAddress).isEmpty == false
            && trimmed(viewModel.ownerVenueCity).isEmpty == false
            && trimmed(viewModel.ownerVenueState).isEmpty == false
            && trimmed(viewModel.ownerVenueZipCode).isEmpty == false
            && trimmed(viewModel.ownerVenuePhone).isEmpty == false
            && trimmed(viewModel.ownerVenueDescription).isEmpty == false
            && trimmed(viewModel.ownerVenueFeatures).isEmpty == false
            && trimmed(viewModel.venueCoverPhotoURL).isEmpty == false
            && trimmed(viewModel.venueMenuPhotoURL).isEmpty == false
    }

    private var claimMissingMessage: String? {
        if trimmed(viewModel.venueCoverPhotoURL).isEmpty || trimmed(viewModel.venueMenuPhotoURL).isEmpty {
            return "Please upload a venue photo and menu photo before submitting."
        }
        if trimmed(viewModel.ownerVenueName).isEmpty { return "Please enter your venue name." }
        if trimmed(viewModel.ownerVenueAddress).isEmpty { return "Please enter your street address." }
        if trimmed(viewModel.ownerVenueCity).isEmpty { return "Please enter your city." }
        if trimmed(viewModel.ownerVenueState).isEmpty { return "Please enter your state." }
        if trimmed(viewModel.ownerVenueZipCode).isEmpty { return "Please enter your ZIP Code." }
        if trimmed(viewModel.ownerVenuePhone).isEmpty { return "Please enter your business phone." }
        if trimmed(viewModel.ownerVenueDescription).isEmpty { return "Please enter a short description." }
        if trimmed(viewModel.ownerVenueFeatures).isEmpty { return "Please enter your venue features." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Venue Owner")
                .font(.headline)
                .fontWeight(.bold)
            
            Text("Claim your venue with basic business information. After GameON verifies ownership, you can manage games, specials, photos, seating, TVs, and game-day details.")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            if !viewModel.isVenueOwnerLoggedIn {
                TextField("Business email", text: $viewModel.venueOwnerEmail)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .padding()
                    .background(Color.gray.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                
                SecureField("Venue owner password", text: $venuePassword)
                    .padding()
                    .background(Color.gray.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                
                Button {
                    Task {
                        // Avoid mixed account state: if a fan user is signed in, sign them out before venue owner auth.
                        if viewModel.isLoggedIn {
                            await viewModel.logoutUser()
                        }
                        if showVenueRegisterMode {
                            await viewModel.registerVenueOwner(
                                email: viewModel.venueOwnerEmail,
                                password: venuePassword
                            )
                        } else {
                            await viewModel.loginVenueOwner(
                                email: viewModel.venueOwnerEmail,
                                password: venuePassword
                            )
                        }
                    }
                } label: {
                    Text(showVenueRegisterMode ? "Create Venue Owner Account" : "Login as Venue Owner")
                        .fontWeight(.bold)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.black)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
        

                Button {
                    showVenueRegisterMode.toggle()
                } label: {
                    Text(showVenueRegisterMode ? "Already have a venue account? Login" : "New venue owner? Register")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(.blue)
                }
                
                if !viewModel.venueAuthErrorMessage.isEmpty {
                    Text(viewModel.venueAuthErrorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } else {
                HStack {
                    Image(systemName: "building.2.fill")
                        .font(.title2)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Venue owner signed in")
                            .fontWeight(.bold)
                        
                        Text(viewModel.venueOwnerEmail.isEmpty ? "venue@watchzone.app" : viewModel.venueOwnerEmail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                }
                .padding()
                .background(Color.green.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                
                HStack {
                    Text("Verification Status")
                        .fontWeight(.bold)
                    
                    Spacer()
                    
                    Text(viewModel.venueClaimStatus)
                        .font(.caption)
                        .fontWeight(.bold)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(viewModel.venueIsApproved ? Color.green.opacity(0.18) : (viewModel.venueClaimSubmitted ? Color.orange.opacity(0.18) : Color.gray.opacity(0.18)))
                        .foregroundStyle(viewModel.venueIsApproved ? Color.green : (viewModel.venueClaimSubmitted ? Color.orange : Color.secondary))
                        .clipShape(Capsule())
                }

                Button {
                    viewModel.checkVenueApprovalStatus()
                    refreshVenuePhotoReviewState()
                } label: {
                    Label("Refresh status", systemImage: "arrow.clockwise")
                        .font(.caption)
                        .fontWeight(.bold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.06))
                        .foregroundStyle(.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                
                if !viewModel.venueClaimSubmitted {
                    TextField("Venue name", text: $viewModel.ownerVenueName)
                        .padding()
                        .background(Color.gray.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 16))

                    TextField("Street Address", text: $viewModel.ownerVenueAddress)
                        .padding()
                        .background(Color.gray.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 16))

                    TextField("City", text: $viewModel.ownerVenueCity)
                        .padding()
                        .background(Color.gray.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 16))

                    TextField("State", text: $viewModel.ownerVenueState)
                        .padding()
                        .background(Color.gray.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 16))

                    TextField("ZIP Code", text: $viewModel.ownerVenueZipCode)
                        .keyboardType(.numberPad)
                        .padding()
                        .background(Color.gray.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 16))

                    TextField("Business phone", text: $viewModel.ownerVenuePhone)
                        .keyboardType(.phonePad)
                        .padding()
                        .background(Color.gray.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 16))

                    TextField("Business website optional", text: $viewModel.ownerVenueWebsite)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .padding()
                        .background(Color.gray.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 16))

                    TextField("Short Description", text: $viewModel.ownerVenueDescription)
                        .padding()
                        .background(Color.gray.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 16))

                    TextField("Features: Big Screens, Patio, Sound On", text: $viewModel.ownerVenueFeatures)
                        .padding()
                        .background(Color.gray.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 16))

                    Stepper("Number of screens: \(viewModel.ownerVenueScreenCount)", value: $viewModel.ownerVenueScreenCount, in: 1...100)
                        .padding()
                        .background(Color.gray.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 16))

                    Toggle("Serves food / drinks", isOn: $viewModel.ownerVenueServesFood)
                    Toggle("WiFi available", isOn: $viewModel.ownerVenueHasWifi)
                    Toggle("Garden / patio", isOn: $viewModel.ownerVenueHasGarden)
                    Toggle("Projector available", isOn: $viewModel.ownerVenueHasProjector)
                    Toggle("Pet friendly", isOn: $viewModel.ownerVenuePetFriendly)
                    
                    VenueClaimPhotoCard(
                        title: "Bar Photo",
                        subtitle: "Main photo of your venue",
                        imageURL: viewModel.venueCoverPhotoURL,
                        isRequired: true
                    )
                    if photoReviewStatus == "pending", pendingCoverUploaded {
                        Text("Pending replacement uploaded")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.orange)
                    }

                    PhotosPicker(selection: $selectedClaimCoverPhoto, matching: .images) {
                        VenueClaimPhotoPickerLabel(
                            text: viewModel.venueCoverPhotoURL.isEmpty ? "Tap to upload bar photo" : "Tap to replace bar photo"
                        )
                    }

                    VenueClaimPhotoCard(
                        title: "Menu Photo",
                        subtitle: "Food or drink menu photo",
                        imageURL: viewModel.venueMenuPhotoURL,
                        isRequired: true
                    )
                    if photoReviewStatus == "pending", pendingMenuUploaded {
                        Text("Pending replacement uploaded")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.orange)
                    }

                    PhotosPicker(selection: $selectedClaimMenuPhoto, matching: .images) {
                        VenueClaimPhotoPickerLabel(
                            text: viewModel.venueMenuPhotoURL.isEmpty ? "Tap to upload menu photo" : "Tap to replace menu photo"
                        )
                    }

                    if !claimPhotoMessage.isEmpty {
                        Text(claimPhotoMessage)
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundStyle(.green)
                    }
                    
                    TextField("Proof note: manager name, business email domain, license, etc.", text: $viewModel.venueProofNote)
                        .padding()
                        .background(Color.gray.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 16))

                    Button {
                        claimValidationMessage = ""
                        if let msg = claimMissingMessage {
                            claimValidationMessage = msg
                            return
                        }
                        viewModel.submitVenueClaim()
                    } label: {
                        Text("Submit Venue Claim")
                            .fontWeight(.bold)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.black)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    .disabled(!isClaimReadyToSubmit)
                    .opacity(isClaimReadyToSubmit ? 1 : 0.55)

                    if !claimValidationMessage.isEmpty {
                        Text(claimValidationMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(viewModel.venueIsApproved ? "Venue Approved" : "Claim Submitted")
                            .font(.headline)
                            .fontWeight(.bold)
                        
                        Text(viewModel.venueIsApproved
                             ? "Your venue has been verified. You can now manage games, specials, seating, TV count, photos, and game-day details."
                             : "Your venue claim is pending review. Once approved, you will be able to manage games, specials, seating, TV count, photos, and game-day details.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        if !viewModel.venueClaimSubmittedDate.isEmpty {
                            Text("Member since \(formattedMemberSince)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding()
                    .background(viewModel.venueIsApproved ? Color.green.opacity(0.10) : Color.orange.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                
                if viewModel.venueIsApproved {
                    if photoReviewStatus == "pending" {
                        Text("Photos Pending Review")
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.orange.opacity(0.16))
                            .foregroundStyle(Color.orange)
                            .clipShape(Capsule())

                        Text("Your updated photos are under review and are not yet public.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        showVenueDashboard = true
                    } label: {
                        Text("Open Venue Dashboard")
                            .fontWeight(.bold)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.black)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                }

                Button {
                    viewModel.isVenueOwnerLoggedIn = false
                    viewModel.venueOwnerMode = false
                    
                    viewModel.isLoggedIn = false
                    viewModel.currentUserEmail = ""
                    
                    viewModel.venueOwnerEmail = ""
                } label: {

                    Text("Log Out Venue Owner")
                        .fontWeight(.bold)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.red.opacity(0.12))
                        .foregroundStyle(.red)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
            }
        }
        .padding()
        .background(Color.white.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .onAppear {
            if viewModel.isVenueOwnerLoggedIn {
                viewModel.checkVenueApprovalStatus()
                refreshVenuePhotoReviewState()
            }
        }
    }

    private var formattedMemberSince: String {

        let rawDate = viewModel.venueClaimSubmittedDate

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]

        if let date = formatter.date(from: rawDate) {
            let displayFormatter = DateFormatter()
            displayFormatter.dateStyle = .long
            displayFormatter.timeStyle = .none
            return displayFormatter.string(from: date)
        }

        return rawDate
    }
}

private struct VenueClaimPhotoPickerLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .fontWeight(.bold)
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.black)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

private struct VenueClaimPhotoCard: View {
    let title: String
    let subtitle: String
    let imageURL: String
    var isRequired: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.headline)
                    .fontWeight(.bold)
                if isRequired {
                    Text("Required")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(imageURL.isEmpty ? Color.red.opacity(0.14) : Color.green.opacity(0.14))
                        .foregroundStyle(imageURL.isEmpty ? Color.red : Color.green)
                        .clipShape(Capsule())
                }
            }

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)

            RoundedRectangle(cornerRadius: 18)
                .fill(Color.gray.opacity(0.10))
                .frame(height: 140)
                .overlay {
                    if imageURL.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "photo")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)

                            Text("No photo uploaded")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        AsyncImage(url: URL(string: imageURL)) { image in
                            image
                                .resizable()
                                .scaledToFill()
                        } placeholder: {
                            ProgressView()
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(isRequired && imageURL.isEmpty ? Color.red.opacity(0.35) : Color.clear, lineWidth: 1)
                )
        }
    }
}
