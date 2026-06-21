import SwiftUI

struct FanProfileShareChatCardView: View {
    let payload: FanProfileSharePayload
    let isFromCurrentUser: Bool
    let showFriendAvatar: Bool
    let friendPreview: UserPreview
    let timestamp: String?
    @ObservedObject var mapViewModel: MapViewModel

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    @State private var refreshedProfile: PublicUserProfileData?
    @State private var didAttemptRefresh = false

    private var displayPayload: FanProfileShareDisplayModel {
        FanProfileShareDisplayModel(
            payload: payload,
            refreshedProfile: refreshedProfile,
            languageCode: appLanguageRaw
        )
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: FGSpacing.sm) {
            if !isFromCurrentUser, showFriendAvatar {
                ProfileAvatarView(preview: friendPreview, size: 30)
                    .frame(width: 34, alignment: .center)
            } else if !isFromCurrentUser {
                Color.clear
                    .frame(width: 34, height: 1)
            }

            VStack(alignment: isFromCurrentUser ? .trailing : .leading, spacing: FGSpacing.xs + 1) {
                cardContent
                    .frame(maxWidth: 280, alignment: .leading)
                    .padding(.horizontal, FGSpacing.md)
                    .padding(.vertical, FGSpacing.sm + 2)
                    .background {
                        RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                            .fill(FGColor.cardBackground(colorScheme))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                            .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
                    }
                    .softCardShadow()

                if let timestamp, !timestamp.isEmpty {
                    Text(timestamp)
                        .font(FGTypography.metadata)
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                        .padding(.horizontal, FGSpacing.xs)
                        .frame(maxWidth: .infinity, alignment: isFromCurrentUser ? .trailing : .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: isFromCurrentUser ? .trailing : .leading)
            .padding(.leading, isFromCurrentUser ? 52 : 0)
            .padding(.trailing, isFromCurrentUser ? 0 : 52)

            if isFromCurrentUser {
                Color.clear
                    .frame(width: 34, height: 1)
            }
        }
        .onAppear {
            print("[ProfileShareDebug] renderedDisplayName=\(displayPayload.displayName)")
        }
        .task(id: payload.profileUserId) {
            guard !didAttemptRefresh else { return }
            didAttemptRefresh = true
            let loaded = await PublicUserProfileService.load(userId: payload.profileUserId)
            await MainActor.run {
                if loaded.isPubliclyVisible,
                   loaded.hasResolvedIdentity,
                   !FanProfileShareMessage.isGenericDisplayName(loaded.displayName) {
                    refreshedProfile = loaded
                } else {
                    refreshedProfile = nil
                }
            }
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                ProfileAvatarView(preview: displayPayload.preview, size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayPayload.displayName)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(1)
                    if let handleLine = displayPayload.handleLine {
                        Text(handleLine)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(displayPayload.detailLines, id: \.self) { line in
                    Text(line)
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(2)
                }
            }

            Button {
                mapViewModel.presentPublicProfile(userId: payload.profileUserId, context: "dm_profile_share_card")
            } label: {
                Text("View Profile")
                    .font(.system(size: 12.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(FGColor.accentBlue)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }
}

private struct FanProfileShareDisplayModel {
    let displayName: String
    let handleLine: String?
    let preview: UserPreview
    let detailLines: [String]

    init(payload: FanProfileSharePayload, refreshedProfile: PublicUserProfileData?, languageCode: String) {
        let snapshot = Self.snapshotModel(from: payload)
        if let refreshedProfile,
           refreshedProfile.hasResolvedIdentity,
           !FanProfileShareMessage.isGenericDisplayName(refreshedProfile.displayName) {
            let enriched = Self.enrichedModel(from: refreshedProfile, languageCode: languageCode)
            displayName = enriched.displayName
            handleLine = enriched.handleLine ?? snapshot.handleLine
            preview = enriched.preview.avatarURLsPreferring(snapshot.preview)
            detailLines = enriched.detailLines.isEmpty ? snapshot.detailLines : enriched.detailLines
        } else {
            displayName = snapshot.displayName
            handleLine = snapshot.handleLine
            preview = snapshot.preview
            detailLines = snapshot.detailLines
        }
    }

    private static func snapshotModel(from payload: FanProfileSharePayload) -> FanProfileShareDisplayModel {
        let avatarURLs = FanProfileShareMessage.resolvedAvatarURLs(
            thumbnail: payload.avatarThumbnailURL,
            full: payload.avatarURL
        )
        let handleLine: String?
        if let handle = payload.handle?.trimmingCharacters(in: .whitespacesAndNewlines), !handle.isEmpty {
            handleLine = "@\(handle.replacingOccurrences(of: "@", with: ""))"
        } else {
            handleLine = nil
        }

        var lines: [String] = []
        if let national = payload.nationalTeamLine?.trimmingCharacters(in: .whitespacesAndNewlines), !national.isEmpty {
            lines.append(national)
        }
        if let crowd = payload.homeCrowdName?.trimmingCharacters(in: .whitespacesAndNewlines), !crowd.isEmpty {
            lines.append("🏟️ \(crowd)")
        }
        if let fanSince = payload.fanSinceLine?.trimmingCharacters(in: .whitespacesAndNewlines), !fanSince.isEmpty {
            lines.append("📅 Fan since \(fanSince)")
        }

        return FanProfileShareDisplayModel(
            displayName: payload.displayName,
            handleLine: handleLine,
            preview: UserPreview(
                id: payload.profileUserId,
                displayName: payload.displayName,
                username: payload.handle,
                email: nil,
                avatarURL: avatarURLs.full,
                avatarThumbnailURL: avatarURLs.thumbnail,
                isBusinessAccount: false
            ),
            detailLines: lines
        )
    }

    private static func enrichedModel(
        from profile: PublicUserProfileData,
        languageCode: String
    ) -> FanProfileShareDisplayModel {
        let avatarURLs = FanProfileShareMessage.resolvedAvatarURLs(
            thumbnail: profile.avatarThumbnailURL,
            full: profile.avatarURL
        )
        let handle = storedUsername(from: profile.publicHandleLine)
        let handleLine = handle.map { "@\($0)" }

        var lines: [String] = []
        if let national = profile.nationalTeam?.displayTitle(languageCode: languageCode) {
            lines.append(national)
        }
        if let crowd = profile.homeCrowd?.name.trimmingCharacters(in: .whitespacesAndNewlines), !crowd.isEmpty {
            lines.append("🏟️ \(crowd)")
        }
        if let fanSince = FanGeoHandleRules.fanSinceMonthYear(from: profile.profileCreatedAt) {
            lines.append("📅 Fan since \(fanSince)")
        }

        return FanProfileShareDisplayModel(
            displayName: profile.displayName,
            handleLine: handleLine,
            preview: UserPreview(
                id: profile.userId,
                displayName: profile.displayName,
                username: handle,
                email: nil,
                avatarURL: avatarURLs.full,
                avatarThumbnailURL: avatarURLs.thumbnail,
                isBusinessAccount: profile.isBusinessAccount
            ),
            detailLines: lines
        )
    }

    private static func storedUsername(from publicHandleLine: String) -> String? {
        let trimmed = publicHandleLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withoutFanSince = trimmed.components(separatedBy: " • ").first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? trimmed
        let stored = withoutFanSince
            .replacingOccurrences(of: "^@+", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stored.isEmpty, !FanProfileShareMessage.isGenericHandle(stored) else { return nil }
        return stored
    }

    private init(displayName: String, handleLine: String?, preview: UserPreview, detailLines: [String]) {
        self.displayName = displayName
        self.handleLine = handleLine
        self.preview = preview
        self.detailLines = detailLines
    }
}

private extension UserPreview {
    func avatarURLsPreferring(_ fallback: UserPreview) -> UserPreview {
        UserPreview(
            id: id,
            displayName: displayName,
            username: username ?? fallback.username,
            email: nil,
            avatarURL: avatarURL ?? fallback.avatarURL,
            avatarThumbnailURL: avatarThumbnailURL ?? fallback.avatarThumbnailURL,
            isBusinessAccount: isBusinessAccount
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
