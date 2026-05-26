import SwiftUI
import UIKit

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
            ZStack {
                fallbackView(
                    displayName: displayName,
                    email: email,
                    style: fallbackStyle,
                    size: size
                )

                SmoothCachedSocialAvatarImage(url: url, size: size)
            }
            .frame(width: size, height: size)
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

private struct SmoothCachedSocialAvatarImage: View {
    let url: URL
    let size: CGFloat

    @State private var uiImage: UIImage?
    @State private var imageOpacity = 0.0

    var body: some View {
        Group {
            if let uiImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .opacity(imageOpacity)
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .task(id: url.absoluteString) {
            imageOpacity = 0
            uiImage = nil

            if let cached = await DiscoverMapImageCache.shared.cachedImage(for: url, bucket: .avatar) {
                guard !Task.isCancelled else { return }
                uiImage = cached
                imageOpacity = 1
                return
            }

            guard let loaded = await DiscoverMapImageCache.shared.image(for: url, bucket: .avatar),
                  !Task.isCancelled else { return }
            uiImage = loaded
            withAnimation(.easeOut(duration: 0.22)) {
                imageOpacity = 1
            }
        }
    }
}
