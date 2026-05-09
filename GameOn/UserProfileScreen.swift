import SwiftUI

/// Minimal profile editor shell; full persistence can be wired back to Supabase later.
struct UserProfileScreen: View {
    @ObservedObject var viewModel: MapViewModel
    var onDone: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Display name") {
                    Text(viewModel.currentUserDisplayName.isEmpty ? "—" : viewModel.currentUserDisplayName)
                        .foregroundStyle(.primary)
                }
                Section("Photo") {
                    if viewModel.currentUserAvatarURL.isEmpty {
                        Text("No profile photo URL loaded.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(viewModel.currentUserAvatarURL)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
            }
            .navigationTitle("My profile")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onDone()
                        dismiss()
                    }
                }
            }
        }
    }
}
