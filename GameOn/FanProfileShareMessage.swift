import Foundation

/// Internal FanGeo chat profile share payload (encoded in `direct_messages.body` — no migration).
struct FanProfileSharePayload: Codable, Equatable, Sendable {
    let v: Int
    let profileUserId: UUID
    let displayName: String
    let handle: String?
    let avatarThumbnailURL: String?
    let avatarURL: String?
    let nationalTeamLine: String?
    let homeCrowdName: String?
    let homeCityLine: String?
    let fanSinceLine: String?
    let sharedByName: String?

    enum CodingKeys: String, CodingKey {
        case v
        case profileUserId = "profile_user_id"
        case displayName = "display_name"
        case handle
        case avatarThumbnailURL = "avatar_thumbnail_url"
        case avatarURL = "avatar_url"
        case nationalTeamLine = "national_team_line"
        case homeCrowdName = "home_crowd_name"
        case homeCityLine = "home_city_line"
        case fanSinceLine = "fan_since_line"
        case sharedByName = "shared_by_name"
    }

    init(
        profileUserId: UUID,
        displayName: String,
        handle: String?,
        avatarThumbnailURL: String?,
        avatarURL: String?,
        nationalTeamLine: String?,
        homeCrowdName: String?,
        homeCityLine: String?,
        fanSinceLine: String?,
        sharedByName: String?
    ) {
        self.v = 1
        self.profileUserId = profileUserId
        self.displayName = displayName
        self.handle = handle
        self.avatarThumbnailURL = avatarThumbnailURL
        self.avatarURL = avatarURL
        self.nationalTeamLine = nationalTeamLine
        self.homeCrowdName = homeCrowdName
        self.homeCityLine = homeCityLine
        self.fanSinceLine = fanSinceLine
        self.sharedByName = sharedByName
    }
}

enum FanProfileShareMessage {
    static let sentinel = "__FG_PROFILE_SHARE_V1__"

    static func payload(
        from profile: PublicUserProfileData,
        sharedByDisplayName: String,
        languageCode: String
    ) -> FanProfileSharePayload? {
        guard profile.isPubliclyVisible else { return nil }

        let trimmedName = profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !isGenericDisplayName(trimmedName) else { return nil }

        let handle = sanitizedPublicHandle(profile.publicHandleLine)
        let nationalTeamLine = profile.nationalTeam?.displayTitle(languageCode: languageCode)
        let homeCrowdName = profile.homeCrowd?.name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let fanSinceLine = FanGeoHandleRules.fanSinceMonthYear(from: profile.profileCreatedAt)
        let avatarURLs = resolvedAvatarURLs(
            thumbnail: profile.avatarThumbnailURL,
            full: profile.avatarURL
        )

        print("[ProfileShareDebug] sourceDisplayName=\(trimmedName)")
        print("[ProfileShareDebug] sourceHandle=\(handle ?? "nil")")
        print("[ProfileShareDebug] sourceAvatarURL=\(avatarURLs.thumbnail ?? avatarURLs.full ?? "nil")")

        return FanProfileSharePayload(
            profileUserId: profile.userId,
            displayName: trimmedName,
            handle: handle,
            avatarThumbnailURL: avatarURLs.thumbnail,
            avatarURL: avatarURLs.full,
            nationalTeamLine: nationalTeamLine?.nilIfEmpty,
            homeCrowdName: homeCrowdName,
            homeCityLine: nil,
            fanSinceLine: fanSinceLine,
            sharedByName: sharedByDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
    }

    static func encodeBody(payload: FanProfileSharePayload) -> String {
        print("[ProfileShareDebug] encodedDisplayName=\(payload.displayName)")
        let preview = previewLine(for: payload)
        guard let jsonData = try? JSONEncoder().encode(payload),
              let json = String(data: jsonData, encoding: .utf8) else {
            return preview
        }
        return "\(preview)\n\(sentinel)\(json)"
    }

    static func decode(from body: String) -> FanProfileSharePayload? {
        guard let range = body.range(of: sentinel) else { return nil }
        let jsonPart = body[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = jsonPart.data(using: .utf8),
              let payload = try? JSONDecoder().decode(FanProfileSharePayload.self, from: data),
              payload.v == 1 else {
            return nil
        }
        return payload
    }

    static func inboxPreview(from body: String) -> String? {
        if let payload = decode(from: body) {
            return previewLine(for: payload)
        }
        guard let sentinelRange = body.range(of: sentinel) else { return nil }
        let prefix = body[..<sentinelRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix.isEmpty ? "Shared a FanGeo profile" : prefix
    }

    static func previewLine(for payload: FanProfileSharePayload) -> String {
        let sharer = payload.sharedByName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sharerPrefix = (sharer?.isEmpty == false) ? "\(sharer!) shared a FanGeo profile: " : "Shared a FanGeo profile: "
        let handleSuffix: String
        if let handle = payload.handle?.trimmingCharacters(in: .whitespacesAndNewlines), !handle.isEmpty {
            handleSuffix = " (@\(handle.replacingOccurrences(of: "@", with: "")))"
        } else {
            handleSuffix = ""
        }
        return "\(sharerPrefix)\(payload.displayName)\(handleSuffix)"
    }

    static func resolvedAvatarURLs(thumbnail: String?, full: String?) -> (thumbnail: String?, full: String?) {
        let thumb = ImageDisplayURL.canonicalStorageURLString(thumbnail)
        let fullURL = ImageDisplayURL.canonicalStorageURLString(full)
        let resolvedThumb = thumb.isEmpty ? (fullURL.isEmpty ? nil : fullURL) : thumb
        let resolvedFull = fullURL.isEmpty ? resolvedThumb : fullURL
        return (resolvedThumb, resolvedFull)
    }

    static func isGenericDisplayName(_ raw: String) -> Bool {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("Fan") == .orderedSame
    }

    static func isGenericHandle(_ raw: String?) -> Bool {
        guard let raw else { return true }
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "@", with: "")
            .lowercased()
        return normalized.isEmpty || normalized == "fan"
    }

    static func sanitizedPublicHandle(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withoutFanSince = trimmed.components(separatedBy: " • ").first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? trimmed
        let stored = withoutFanSince
            .replacingOccurrences(of: "^@+", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stored.isEmpty, !isGenericHandle(stored) else { return nil }
        return stored
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
