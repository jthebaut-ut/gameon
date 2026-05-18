import SwiftUI

/// Overlapping avatars for “who’s going” rows (Discover / venue preview).
struct GoingAvatarStack: View {
    let profiles: [UserProfileRow]
    var viewerUserID: UUID? = nil
    var maxVisible: Int = 3
    var diameter: CGFloat = 30

    private var visibleProfiles: [UserProfileRow] {
        profiles.filter { $0.isFanVisibleForLivePresence(to: viewerUserID) }
    }

    var body: some View {
        let visible = visibleProfiles
        let trimmed = Array(visible.prefix(maxVisible))
        let overflow = max(visible.count - trimmed.count, 0)
        let _: Void = logAvatarFiltering(rawCount: profiles.count, visible: visible)

        if !trimmed.isEmpty {
            HStack(spacing: -diameter * 0.34) {
                ForEach(Array(trimmed.enumerated()), id: \.offset) { _, row in
                    avatar(for: row)
                        .frame(width: diameter, height: diameter)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.white, lineWidth: 2))
                        .shadow(color: Color.black.opacity(0.16), radius: 4, y: 2)
                }

                if overflow > 0 {
                    Text("+\(overflow)")
                        .font(.system(size: max(10, diameter * 0.34), weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                        .frame(width: diameter, height: diameter)
                        .background(Color(.systemBackground))
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.white, lineWidth: 2))
                        .shadow(color: Color.black.opacity(0.14), radius: 4, y: 2)
                }
            }
            .animation(.easeOut(duration: 0.18), value: visible.count)
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

    private func logAvatarFiltering(rawCount: Int, visible: [UserProfileRow]) {
#if DEBUG
        DebugLogGate.noisy("[LiveAvatarDebug] stackRawCount=\(rawCount)")
        DebugLogGate.noisy("[LiveAvatarDebug] stackVisibleIds=\(visible.compactMap { $0.id?.uuidString.lowercased() })")
        DebugLogGate.noisy("[LiveAvatarDebug] stackFilteredCount=\(max(rawCount - visible.count, 0))")
#endif
    }
}
