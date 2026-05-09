import SwiftUI
import PhotosUI

struct UserProfileScreen: View {
    @ObservedObject var viewModel: MapViewModel
    var onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var editedDisplayName: String = ""
    @State private var selectedAvatarItem: PhotosPickerItem?
    @State private var isSaving: Bool = false
    @State private var isUploadingAvatar: Bool = false
    @State private var message: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        profileAvatar

                        VStack(alignment: .leading, spacing: 2) {
                            Text(resolvedDisplayName.isEmpty ? "My profile" : resolvedDisplayName)
                                .font(.headline.weight(.semibold))
                            Text(viewModel.currentUserEmail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                }

                Section("Display name") {
                    TextField("Name", text: $editedDisplayName)
                        .textInputAutocapitalization(.words)
                        .disableAutocorrection(true)

                    Text("This name is shown across GameOn and is independent from your email.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Photo") {
                    PhotosPicker(selection: $selectedAvatarItem, matching: .images) {
                        HStack {
                            Text("Update avatar")
                            Spacer()
                            if isUploadingAvatar {
                                ProgressView()
                            } else {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(isUploadingAvatar || isSaving)

                    if !viewModel.currentUserAvatarURL.isEmpty {
                        Text("Your avatar is stored securely and can be replaced anytime.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !message.isEmpty {
                    Section {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .disabled(isSaving || isUploadingAvatar)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving..." : "Save") {
                        Task { await saveProfile() }
                    }
                    .disabled(isSaving || isUploadingAvatar)
                }
            }
            .onAppear {
                editedDisplayName = resolvedDisplayName
            }
            .onChange(of: selectedAvatarItem) { _, item in
                guard let item else { return }
                Task { await replaceAvatar(with: item) }
            }
        }
    }

    private var resolvedDisplayName: String {
        let current = viewModel.currentUserDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty { return current }
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

    private var profileAvatar: some View {
        ZStack {
            Circle().fill(Color.gray.opacity(0.18))
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
        .frame(width: 56, height: 56)
        .clipShape(Circle())
    }

    private func saveProfile() async {
        guard viewModel.isLoggedIn else {
            await MainActor.run { message = "Please sign in to edit your profile." }
            return
        }

        isSaving = true
        defer { isSaving = false }

        let trimmed = editedDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextName = trimmed.isEmpty ? resolvedDisplayName : trimmed
        await viewModel.saveUserProfile(displayName: nextName, avatarURL: viewModel.currentUserAvatarURL)
        await MainActor.run { message = "Saved." }
        onDone()
    }

    private func replaceAvatar(with item: PhotosPickerItem) async {
        guard viewModel.isLoggedIn else {
            await MainActor.run { message = "Please sign in to update your avatar." }
            return
        }

        isUploadingAvatar = true
        defer { isUploadingAvatar = false }
        await MainActor.run { message = "Uploading avatar..." }

        let oldURL = viewModel.currentUserAvatarURL
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            await MainActor.run { message = "Unable to read photo." }
            return
        }
        guard let newURL = await viewModel.uploadUserAvatar(data: data, fileName: "avatar.jpg") else {
            await MainActor.run { message = "Unable to upload avatar." }
            return
        }

        let trimmed = editedDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextName = trimmed.isEmpty ? resolvedDisplayName : trimmed
        await viewModel.saveUserProfile(displayName: nextName, avatarURL: newURL)
        await viewModel.deleteUserAvatarIfPossible(previousAvatarURL: oldURL)
        await MainActor.run { message = "Avatar updated." }
    }
}
