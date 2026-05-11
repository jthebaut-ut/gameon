import SwiftUI

enum SocialAvatarRenderer {
    enum FallbackStyle {
        case genericPerson
        case grayInitials
        case blueInitials
    }

    @ViewBuilder
    static func socialAvatarView(for preview: UserPreview, size: CGFloat) -> some View {
        socialAvatarView(
            displayName: preview.displayName,
            email: nil,
            avatarURL: preview.avatarURL,
            avatarThumbnailURL: preview.avatarThumbnailURL,
            isBusinessIdentity: preview.isBusinessIdentity,
            size: size,
            fallbackStyle: .genericPerson
        )
    }

    @ViewBuilder
    static func socialAvatarView(
        for profile: UserProfileRow,
        size: CGFloat,
        fallbackStyle: FallbackStyle = .grayInitials
    ) -> some View {
        socialAvatarView(
            displayName: profile.display_name ?? "",
            email: profile.email,
            avatarURL: profile.avatar_url,
            avatarThumbnailURL: profile.avatar_thumbnail_url,
            isBusinessIdentity: profile.isBusinessIdentity,
            size: size,
            fallbackStyle: fallbackStyle
        )
    }

    @ViewBuilder
    static func socialAvatarView(
        displayName: String,
        email: String?,
        avatarURL: String?,
        avatarThumbnailURL: String?,
        isBusinessIdentity: Bool,
        size: CGFloat,
        fallbackStyle: FallbackStyle
    ) -> some View {
        if isBusinessIdentity {
            BusinessAvatarIconView(size: size)
        } else if let raw = ImageDisplayURL.forList(thumbnail: avatarThumbnailURL, full: avatarURL),
                  let url = URL(string: raw) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                default:
                    fallbackView(
                        displayName: displayName,
                        email: email,
                        style: fallbackStyle,
                        size: size
                    )
                }
            }
        } else {
            fallbackView(
                displayName: displayName,
                email: email,
                style: fallbackStyle,
                size: size
            )
        }
    }

    @ViewBuilder
    private static func fallbackView(
        displayName: String,
        email: String?,
        style: FallbackStyle,
        size: CGFloat
    ) -> some View {
        switch style {
        case .genericPerson:
            Image(systemName: "person.circle.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
        case .grayInitials:
            let initial = fallbackInitial(displayName: displayName, email: email)
            ZStack {
                Color(.systemGray4)
                Text(initial)
                    .font(.system(size: max(11, size * 0.34), weight: .bold))
                    .foregroundStyle(.secondary)
            }
        case .blueInitials:
            let initial = fallbackInitial(displayName: displayName, email: email)
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.15))
                Text(initial)
                    .font(.system(size: max(11, size * 0.34), weight: .bold))
                    .foregroundStyle(.blue)
            }
        }
    }

    private static func fallbackInitial(displayName: String, email: String?) -> String {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = name.first {
            return String(first).uppercased()
        }
        let mail = (email ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = mail.first {
            return String(first).uppercased()
        }
        return "?"
    }
}
