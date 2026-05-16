import SwiftUI

/// Wraps an avatar chip so tapping opens ``PublicUserProfilePreviewView`` for another user.
struct PublicProfileAvatarTap<Content: View>: View {
    let userId: UUID?
    let context: String
    @ViewBuilder let content: () -> Content

    @EnvironmentObject private var viewModel: MapViewModel

    var body: some View {
        if let userId, userId != viewModel.currentUserAuthId {
            Button {
                viewModel.presentPublicProfile(userId: userId, context: context)
            } label: {
                content()
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens profile preview")
        } else {
            content()
        }
    }
}
