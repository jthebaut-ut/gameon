import SwiftUI

/// Overlapping avatars for “who’s going” rows (Discover / venue preview).
struct GoingAvatarStack: View {
    let profiles: [UserProfileRow]

    private let maxVisible = 4
    private let diameter: CGFloat = 32

    var body: some View {
        let trimmed = Array(profiles.prefix(maxVisible))
        HStack(spacing: -diameter * 0.35) {
            ForEach(Array(trimmed.enumerated()), id: \.offset) { _, row in
                avatar(for: row)
                    .frame(width: diameter, height: diameter)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.white, lineWidth: 2))
            }
        }
    }

    @ViewBuilder
    private func avatar(for row: UserProfileRow) -> some View {
        if let userId = row.id {
            PublicProfileAvatarTap(userId: userId, context: "going_avatar_stack") {
                SocialAvatarRenderer.socialAvatarView(
                    for: row,
                    size: diameter,
                    fallbackStyle: .grayInitials
                )
            }
        } else {
            SocialAvatarRenderer.socialAvatarView(
                for: row,
                size: diameter,
                fallbackStyle: .grayInitials
            )
        }
    }
}
