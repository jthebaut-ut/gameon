import Foundation

extension MapViewModel {
    func cachedVenueEventRow(for bar: BarVenue, gameTitle: String) -> VenueEventRow? {
        venueEventRows.first { row in
            let storedTitle = row.event_title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let publicTitle = VenueGameCompetitorDisplay.publicTitle(
                eventTitle: row.event_title,
                sport: row.sport,
                homeTeam: row.home_team,
                awayTeam: row.away_team
            )
            guard storedTitle.caseInsensitiveCompare(gameTitle) == .orderedSame
                    || publicTitle.caseInsensitiveCompare(gameTitle) == .orderedSame else {
                return false
            }
            if let venueID = row.venue_id, venueID == bar.id { return true }
            if row.venue_name == bar.name { return true }
            if let owner = row.owner_email,
               let barOwner = bar.ownerEmail,
               OwnerBusinessEmail.normalized(owner) == OwnerBusinessEmail.normalized(barOwner) {
                return true
            }
            return false
        }
    }

    func liveEnergy(
        for bar: BarVenue,
        event: SportsEvent?,
        friendUserIDs: Set<UUID> = []
    ) -> FanGeoLiveEnergy {
        let row = event.flatMap { cachedVenueEventRow(for: bar, gameTitle: $0.title) }
        let eventID = row?.id ?? event.flatMap { cachedVenueEventID(for: bar, gameTitle: $0.title) }
        let startDate = row.flatMap { FanGeoLiveEnergyTiming.parseScheduledStart($0.scheduled_start_at, eventId: $0.id) }
            ?? event.flatMap { liveEnergyFallbackStartDate(for: $0) }

        let commentCount = eventID.map { fanUpdatesDisplayCommentCount(for: $0) } ?? 0
        let profiles = eventID.map { goingProfiles(for: $0) } ?? []
        let totalGoingCount = eventID == nil ? max(displayedGoingCount(for: bar), 0) : profiles.count
        let friendProfiles = profiles.filter { profile in
            guard let id = profile.id else { return false }
            return friendUserIDs.contains(id)
        }
        let friendGoingCount = friendProfiles.count
        let fanGoingCount = max(totalGoingCount - friendGoingCount, 0)
        let socialProfiles = liveEnergyPrioritizedPresenceProfiles(
            profiles,
            friendUserIDs: friendUserIDs
        )
        let friendAvatarURLs = friendProfiles.compactMap { profile in
            let raw = profile.avatar_thumbnail_url ?? profile.avatar_url
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }

        let now = Date()
        let minutesUntilStart: Int?
        let isLiveNow: Bool
        let startsSoon: Bool
        if let startDate {
            let secondsUntil = startDate.timeIntervalSince(now)
            let liveEnd = startDate.addingTimeInterval(TimeInterval(FanGeoLiveEnergyTiming.liveWindowHours * 3600))
            minutesUntilStart = secondsUntil > 0 ? max(0, Int(ceil(secondsUntil / 60))) : nil
            isLiveNow = now >= startDate && now <= liveEnd
            startsSoon = secondsUntil > 0 && secondsUntil <= TimeInterval(FanGeoLiveEnergyTiming.startsSoonWindowMinutes * 60)
        } else {
            minutesUntilStart = nil
            isLiveNow = false
            startsSoon = false
        }

        let energyLabel = liveEnergyLabel(
            isLiveNow: isLiveNow,
            startsSoon: startsSoon,
            minutesUntilStart: minutesUntilStart,
            goingCount: totalGoingCount,
            commentCount: commentCount
        )
        let friendLabel = liveEnergyFriendPresenceLabel(friendProfiles)
        let socialLabel = liveEnergySocialPresenceLabel(
            totalGoingCount: totalGoingCount,
            friendGoingCount: friendGoingCount,
            fanGoingCount: fanGoingCount
        )
        let subtitle = liveEnergySubtitle(
            isLiveNow: isLiveNow,
            startsSoon: startsSoon,
            minutesUntilStart: minutesUntilStart,
            goingCount: totalGoingCount,
            commentCount: commentCount,
            friendGoingCount: friendGoingCount
        )

        let energy = FanGeoLiveEnergy(
            isLiveNow: isLiveNow,
            startsSoon: startsSoon,
            minutesUntilStart: minutesUntilStart,
            goingCount: totalGoingCount,
            commentCount: commentCount,
            friendGoingCount: friendGoingCount,
            friendAvatarURLs: friendAvatarURLs,
            mutualTeamLabel: nil,
            energyLabel: energyLabel,
            energySubtitle: subtitle,
            friendPresenceLabel: friendLabel,
            friendProfiles: friendProfiles,
            socialPresenceProfiles: socialProfiles,
            socialPresenceLabel: socialLabel
        )

#if DEBUG
        DebugLogGate.noisy("[LiveEnergyDebug] venueId=\(bar.id.uuidString.lowercased())")
        DebugLogGate.noisy("[LiveEnergyDebug] eventId=\(eventID?.uuidString.lowercased() ?? "nil")")
        DebugLogGate.noisy("[LiveEnergyDebug] isLiveNow=\(energy.isLiveNow)")
        DebugLogGate.noisy("[LiveEnergyDebug] startsSoon=\(energy.startsSoon)")
        DebugLogGate.noisy("[LiveEnergyDebug] goingCount=\(energy.goingCount)")
        DebugLogGate.noisy("[LiveEnergyDebug] friendGoingCount=\(energy.friendGoingCount)")
        DebugLogGate.noisy("[VenueGoingCountDebug] totalGoingCount=\(totalGoingCount)")
        DebugLogGate.noisy("[VenueGoingCountDebug] friendGoingCount=\(friendGoingCount)")
        DebugLogGate.noisy("[VenueGoingCountDebug] visibleProfileIds=\(profiles.compactMap { $0.id?.uuidString.lowercased() })")
        DebugLogGate.noisy("[LiveEnergyDebug] energyLabel=\(energy.energyLabel ?? "nil")")
        DebugLogGate.noisy("[FriendPresenceDebug] friendIdsGoing=\(friendProfiles.compactMap { $0.id?.uuidString.lowercased() })")
        DebugLogGate.noisy("[FriendPresenceDebug] mutualTeamLabel=\(energy.mutualTeamLabel ?? "nil")")
        DebugLogGate.noisy("[LiveAvatarDebug] rawCandidateCount=\(eventID.flatMap { goingProfilesByVenueEventID[$0]?.count } ?? 0)")
        DebugLogGate.noisy("[LiveAvatarDebug] visibleCandidateIds=\(profiles.compactMap { $0.id?.uuidString.lowercased() })")
        DebugLogGate.noisy("[LiveAvatarDebug] prioritizedVisibleIds=\(socialProfiles.compactMap { $0.id?.uuidString.lowercased() })")
        DebugLogGate.noisy("[LiveAvatarDebug] filteredHiddenOrBusinessCount=\(max((eventID.flatMap { goingProfilesByVenueEventID[$0]?.count } ?? 0) - profiles.count, 0))")
#endif

        return energy
    }

    func strongestLiveEnergy(
        for bar: BarVenue,
        events: [SportsEvent],
        friendUserIDs: Set<UUID> = []
    ) -> FanGeoLiveEnergy? {
        events
            .map { liveEnergy(for: bar, event: $0, friendUserIDs: friendUserIDs) }
            .filter(\.hasAnySignal)
            .sorted { lhs, rhs in
                liveEnergySortScore(lhs) > liveEnergySortScore(rhs)
            }
            .first
    }

    func hasLiveVenueEventNow(for bar: BarVenue, events: [SportsEvent]) -> Bool {
        let now = Date()
        return events.contains { event in
            guard let row = cachedVenueEventRow(for: bar, gameTitle: event.title),
                  let start = FanGeoLiveEnergyTiming.parseScheduledStart(row.scheduled_start_at, eventId: row.id) else {
                return false
            }
            let liveEnd = start.addingTimeInterval(TimeInterval(FanGeoLiveEnergyTiming.liveWindowHours * 3600))
            return now >= start && now <= liveEnd
        }
    }

    private func liveEnergySortScore(_ energy: FanGeoLiveEnergy) -> Int {
        (energy.isLiveNow ? 10_000 : 0)
            + (energy.startsSoon ? 5_000 : 0)
            + (energy.friendGoingCount * 100)
            + (energy.goingCount * 10)
            + energy.commentCount
    }

    private func liveEnergyLabel(
        isLiveNow: Bool,
        startsSoon: Bool,
        minutesUntilStart: Int?,
        goingCount: Int,
        commentCount: Int
    ) -> String? {
        if isLiveNow { return "LIVE NOW" }
        if startsSoon, goingCount > 0 { return "Crowd building" }
        if startsSoon, let minutesUntilStart { return "Game starts in \(minutesUntilStart) min" }
        if goingCount > 0 { return "Fans going" }
        if commentCount > 0 { return "Fans chatting" }
        return nil
    }

    private func liveEnergySubtitle(
        isLiveNow: Bool,
        startsSoon: Bool,
        minutesUntilStart: Int?,
        goingCount: Int,
        commentCount: Int,
        friendGoingCount: Int
    ) -> String? {
        var parts: [String] = []
        if isLiveNow {
            parts.append("Watch party active")
        } else if startsSoon, let minutesUntilStart {
            parts.append("Game starts in \(minutesUntilStart) min")
        }
        if goingCount > 0 {
            parts.append(goingCount == 1 ? "1 fan going" : "\(goingCount) fans going")
        }
        if friendGoingCount > 0 {
            parts.append(friendGoingCount == 1 ? "1 friend going" : "\(friendGoingCount) friends going")
        }
        if commentCount > 0 {
            parts.append(commentCount == 1 ? "1 chatting" : "\(commentCount) chatting")
        }
        return parts.isEmpty ? "Be the first fan there" : parts.joined(separator: " • ")
    }

    private func liveEnergyFriendPresenceLabel(_ friendProfiles: [UserProfileRow]) -> String? {
        guard !friendProfiles.isEmpty else { return nil }
        if friendProfiles.count == 1 {
            let name = liveEnergyFirstName(friendProfiles[0])
            return name.map { "\($0) is going" } ?? "1 friend going"
        }
        let name = liveEnergyFirstName(friendProfiles[0])
        if let name {
            return "\(name) and \(friendProfiles.count - 1) others are going"
        }
        return "\(friendProfiles.count) friends going"
    }

    private func liveEnergyPrioritizedPresenceProfiles(
        _ profiles: [UserProfileRow],
        friendUserIDs: Set<UUID>
    ) -> [UserProfileRow] {
        var seen: Set<UUID> = []
        func appendUnique(_ source: [UserProfileRow], to result: inout [UserProfileRow]) {
            for profile in source {
                guard let id = profile.id else { continue }
                guard !seen.contains(id) else { continue }
                seen.insert(id)
                result.append(profile)
            }
        }

        let friends = profiles.filter { profile in
            guard let id = profile.id else { return false }
            return friendUserIDs.contains(id)
        }
        let otherVisibleFans = profiles.filter { profile in
            guard let id = profile.id else { return false }
            return !friendUserIDs.contains(id)
        }

        var prioritized: [UserProfileRow] = []
        appendUnique(friends, to: &prioritized)
        appendUnique(otherVisibleFans, to: &prioritized)
        return prioritized
    }

    private func liveEnergySocialPresenceLabel(
        totalGoingCount: Int,
        friendGoingCount: Int,
        fanGoingCount: Int
    ) -> String? {
        let displayedGoingCount = max(totalGoingCount, friendGoingCount + fanGoingCount)
        guard displayedGoingCount > 0 else { return nil }

        let goingText = "\(displayedGoingCount) going"
        guard friendGoingCount > 0 else { return goingText }

        let friendText = friendGoingCount == 1 ? "1 friend" : "\(friendGoingCount) friends"
        return "\(goingText) · \(friendText)"
    }

    private func liveEnergyFirstName(_ profile: UserProfileRow) -> String? {
        let display = (profile.display_name ?? profile.username ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !display.isEmpty else { return nil }
        return display.split(separator: " ").first.map(String.init)
    }

    private func liveEnergyFallbackStartDate(for event: SportsEvent) -> Date? {
        let trimmedTime = event.time.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTime.isEmpty, trimmedTime.lowercased() != "time tbd" else {
            return Calendar.current.startOfDay(for: event.date)
        }

        let formats = ["h:mm a", "h a", "HH:mm", "HH:mm:ss"]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            guard let parsedTime = formatter.date(from: trimmedTime) else { continue }
            let dateParts = Calendar.current.dateComponents([.year, .month, .day], from: event.date)
            let timeParts = Calendar.current.dateComponents([.hour, .minute, .second], from: parsedTime)
            var merged = DateComponents()
            merged.year = dateParts.year
            merged.month = dateParts.month
            merged.day = dateParts.day
            merged.hour = timeParts.hour
            merged.minute = timeParts.minute
            merged.second = timeParts.second
            return Calendar.current.date(from: merged)
        }

        return Calendar.current.startOfDay(for: event.date)
    }
}
