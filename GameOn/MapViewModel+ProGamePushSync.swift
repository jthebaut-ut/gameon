import Foundation
import Combine
import Supabase

nonisolated enum FavoriteTeamProGameAlertOverride: String, Codable, Equatable {
    case inherit
    case on
    case off
    case muted

    var explicitlyEnablesAlerts: Bool {
        self == .on
    }

    var explicitlyDisablesAlerts: Bool {
        self == .off || self == .muted
    }
}

extension MapViewModel {
    func syncProGameFinalScorePreferenceToBackend(reason: String) async {
        guard let userID = currentUserAuthId, isAuthenticatedForSocialFeatures else { return }
        let timing = notificationSettingsStore.proGameReminderTiming
        let row = ProGameNotificationPreferenceUpsertRow(
            user_id: userID.uuidString.lowercased(),
            pro_game_reminder_notifications_enabled: timing.schedulesKickoffReminder,
            pro_game_reminder_timing: timing.rawValue,
            pro_game_final_score_alerts_enabled: notificationSettingsStore.proGameFinalScoreNotifications,
            favorite_team_pro_game_alerts_enabled: notificationSettingsStore.favoriteTeamProGameAlertsEnabled
        )

        do {
            try await supabase
                .from("user_notification_preferences")
                .upsert(row, onConflict: "user_id")
                .execute()
#if DEBUG
            print("[RemoteNotificationDebug] proGamePreferenceSyncSucceeded reminders=\(row.pro_game_reminder_notifications_enabled) timing=\(row.pro_game_reminder_timing) final=\(row.pro_game_final_score_alerts_enabled) reason=\(reason)")
#endif
        } catch {
#if DEBUG
            print("[RemoteNotificationDebug] proGamePreferenceSyncFailed reason=\(reason) error=\(error.localizedDescription)")
#endif
        }
    }

    func loadProGameNotificationPreferencesFromBackend(reason: String) async {
        guard let userID = currentUserAuthId, isAuthenticatedForSocialFeatures else { return }
        do {
            let rows: [ProGameNotificationPreferenceRow] = try await supabase
                .from("user_notification_preferences")
                .select("pro_game_reminder_notifications_enabled,pro_game_reminder_timing,pro_game_final_score_alerts_enabled,favorite_team_pro_game_alerts_enabled")
                .eq("user_id", value: userID.uuidString.lowercased())
                .limit(1)
                .execute()
                .value

            if let row = rows.first {
                applyProGameNotificationPreferences(from: row, reason: reason)
                return
            }

            await syncProGameFinalScorePreferenceToBackend(reason: "preferencesSeed")
#if DEBUG
            print("[RemoteNotificationDebug] proGamePreferenceLoaded=seeded reason=\(reason)")
#endif
        } catch {
#if DEBUG
            print("[RemoteNotificationDebug] proGamePreferenceLoadFailed reason=\(reason) error=\(error.localizedDescription)")
#endif
        }
    }

    func loadFavoriteTeamProGameAlertsPreferenceFromBackend(reason: String) async {
        await loadProGameNotificationPreferencesFromBackend(reason: reason)
    }

    private func applyProGameNotificationPreferences(from row: ProGameNotificationPreferenceRow, reason: String) {
        if let timingRaw = row.pro_game_reminder_timing?.trimmingCharacters(in: .whitespacesAndNewlines),
           !timingRaw.isEmpty {
            notificationSettingsStore.proGameReminderTiming = ProGameReminderTiming.resolved(rawValue: timingRaw)
        } else if row.pro_game_reminder_notifications_enabled == false {
            notificationSettingsStore.proGameReminderTiming = .never
        }

        if let finalAlerts = row.pro_game_final_score_alerts_enabled {
            notificationSettingsStore.proGameFinalScoreNotifications = finalAlerts
        }
        if let teamAlerts = row.favorite_team_pro_game_alerts_enabled {
            notificationSettingsStore.favoriteTeamProGameAlertsEnabled = teamAlerts
        }

        objectWillChange.send()
        Task { [weak self] in
            guard let self else { return }
            await self.proGameReminderPreferenceDidChange()
        }
#if DEBUG
        print("[RemoteNotificationDebug] proGamePreferenceLoaded timing=\(notificationSettingsStore.proGameReminderTiming.rawValue) final=\(notificationSettingsStore.proGameFinalScoreNotifications) teamAlerts=\(notificationSettingsStore.favoriteTeamProGameAlertsEnabled) reason=\(reason)")
#endif
    }

    func syncProGameScoreAlertPreferenceToBackend(_ enabled: Bool, for game: SavedProGame) async {
        guard let userID = currentUserAuthId, isAuthenticatedForSocialFeatures else { return }
        if savedProGames.contains(where: { $0.stableKey == game.stableKey }) {
            await syncSavedProGameScoreAlertPreference(enabled, for: game, userID: userID)
            return
        }

        guard let favoriteTeamGame = favoriteTeamSubscriptionMatch(for: game) else {
#if DEBUG
            print("[RemoteNotificationDebug] scoreAlertSyncSkipped id=\(game.stableKey) reason=noSavedOrFavoriteSubscription")
#endif
            return
        }
        await upsertFavoriteTeamProGameSubscriptions(
            [favoriteTeamGame],
            userID: userID,
            reason: "scoreAlertToggle",
            subscriptionSource: "manual",
            scoreAlertsEnabledOverride: enabled,
            finalAlertsEnabledOverride: enabled ? notificationSettingsStore.proGameFinalScoreNotifications : false
        )
    }

    func syncFavoriteTeamProGameSubscriptions(_ games: [FavoriteTeamProGame], reason: String) async {
        guard let userID = currentUserAuthId, isAuthenticatedForSocialFeatures else { return }
#if DEBUG
        print("[TeamAlertsDebug] favoriteTeamGamesEvaluated=\(games.count) reason=\(reason)")
#endif
        let autoGames = games.filter { item in
            !savedProGames.contains(where: { $0.stableKey == item.game.stableKey })
        }
        await loadFavoriteTeamProGameAlertOverrides(for: autoGames, userID: userID, reason: reason)
        await upsertFavoriteTeamProGameSubscriptions(
            autoGames,
            userID: userID,
            reason: reason,
            subscriptionSource: "favorite_team_auto"
        )
        await syncFavoriteTeamProGamesToAppleCalendar(
            games,
            reason: reason,
            forceBypassFreshness: true
        )
        if !notificationSettingsStore.favoriteTeamProGameAlertsEnabled {
            await disableFavoriteTeamAutoDefaultSubscriptions(userID: userID, reason: reason)
        }
    }

    func setFavoriteTeamProGameAlertsEnabled(_ enabled: Bool, games: [FavoriteTeamProGame], reason: String) async {
        guard let userID = currentUserAuthId, isAuthenticatedForSocialFeatures else { return }
        if enabled {
            _ = await GameReminderNotificationService.shared.requestAuthorizationIfNeeded()
            await PushNotificationRegistrationService.shared.registerForRemoteNotificationsIfAuthorized(reason: "teamAlertsEnabled")
        }
        notificationSettingsStore.favoriteTeamProGameAlertsEnabled = enabled
        objectWillChange.send()
        await syncProGameFinalScorePreferenceToBackend(reason: "teamAlertsToggle")
#if DEBUG
        print("[TeamAlertsDebug] settingUpdated=\(enabled) reason=\(reason)")
#endif
        let autoGames = games.filter { item in
            !savedProGames.contains(where: { $0.stableKey == item.game.stableKey })
        }
        await loadFavoriteTeamProGameAlertOverrides(for: autoGames, userID: userID, reason: reason)
        await upsertFavoriteTeamProGameSubscriptions(
            autoGames,
            userID: userID,
            reason: reason,
            subscriptionSource: "favorite_team_auto"
        )
        if !enabled {
            await disableFavoriteTeamAutoDefaultSubscriptions(userID: userID, reason: reason)
        }
    }

    func favoriteTeamProGameAlertOverride(for game: SavedProGame) -> FavoriteTeamProGameAlertOverride {
        favoriteTeamProGameAlertOverrides[game.stableKey] ?? .inherit
    }

    func favoriteTeamProGameAlertsMuted(for game: SavedProGame) -> Bool {
        favoriteTeamProGameAlertOverride(for: game).explicitlyDisablesAlerts
    }

    func setFavoriteTeamProGameScoreUpdatesEnabled(
        _ enabled: Bool,
        for item: FavoriteTeamProGame,
        reason: String
    ) {
        if enabled {
            Task {
                _ = await GameReminderNotificationService.shared.requestAuthorizationIfNeeded()
                await PushNotificationRegistrationService.shared.registerForRemoteNotificationsIfAuthorized(reason: "favoriteTeamGameAlertEnabled")
            }
        }
        setFavoriteTeamProGameAlertOverride(
            enabled ? .on : .off,
            for: item,
            reason: reason
        )
    }

    func setFavoriteTeamProGameAlertOverride(
        _ override: FavoriteTeamProGameAlertOverride,
        for item: FavoriteTeamProGame,
        reason: String
    ) {
        let key = item.game.stableKey
        favoriteTeamProGameAlertOverrides[key] = override
        objectWillChange.send()
        Task { [weak self] in
            guard let self else { return }
            await self.syncFavoriteTeamProGameAlertOverride(override, for: item, reason: reason)
        }
    }

    private func syncSavedProGameScoreAlertPreference(_ enabled: Bool, for game: SavedProGame, userID: UUID) async {
        let patch = SavedProGameScoreAlertPatch(
            score_alerts_enabled: enabled,
            final_score_alerts_enabled: notificationSettingsStore.proGameFinalScoreNotifications,
            last_notified_scoreline: enabled ? proGameScoreline(for: game) : nil,
            score_alerts_updated_at: SupabaseTimestampParsing.encodeTimestamptz(Date())
        )

        do {
            try await supabase
                .from("saved_pro_games")
                .update(patch)
                .eq("user_id", value: userID.uuidString.lowercased())
                .eq("live_match_id", value: game.stableKey)
                .execute()
#if DEBUG
            print("[RemoteNotificationDebug] savedScoreAlertSyncSucceeded id=\(game.stableKey) enabled=\(enabled)")
#endif
        } catch {
#if DEBUG
            print("[RemoteNotificationDebug] savedScoreAlertSyncFailed id=\(game.stableKey) error=\(error.localizedDescription)")
#endif
        }
    }

    private func upsertFavoriteTeamProGameSubscriptions(
        _ games: [FavoriteTeamProGame],
        userID: UUID,
        reason: String,
        subscriptionSource: String,
        scoreAlertsEnabledOverride: Bool? = nil,
        finalAlertsEnabledOverride: Bool? = nil
    ) async {
        let rows = games.map { item in
            let game = item.game
            let alertOverride = subscriptionSource == "favorite_team_auto"
                ? favoriteTeamProGameAlertOverride(for: game)
                : nil
            let scoreAlertsEnabled = scoreAlertsEnabledOverride ?? favoriteTeamProGameScoreUpdatesEnabled(for: game)
            let finalAlertsEnabled = finalAlertsEnabledOverride ?? (scoreAlertsEnabled && notificationSettingsStore.proGameFinalScoreNotifications)
            return FavoriteTeamProGameAlertSubscriptionUpsertRow(
                user_id: userID.uuidString.lowercased(),
                live_match_id: game.stableKey,
                subscription_source: subscriptionSource,
                alert_override: alertOverride?.rawValue,
                favorite_team_id: item.favoriteTeamID,
                favorite_team_name: item.favoriteTeamName,
                source: cleanedProGamePushValue(game.source),
                external_id: cleanedProGamePushValue(game.externalId),
                home_team: game.homeTeam,
                away_team: game.awayTeam,
                league: cleanedProGamePushValue(game.league),
                sport: cleanedProGamePushValue(game.sport),
                start_time: SupabaseTimestampParsing.encodeTimestamptz(game.startTime),
                match_status: game.matchStatus.rawValue,
                score_home: game.scoreHome,
                score_away: game.scoreAway,
                score_alerts_enabled: scoreAlertsEnabled,
                final_score_alerts_enabled: finalAlertsEnabled,
                last_notified_scoreline: scoreAlertsEnabled ? proGameScoreline(for: game) : nil
            )
        }
        guard !rows.isEmpty else { return }

        do {
            try await supabase
                .from("pro_game_alert_subscriptions")
                .upsert(rows, onConflict: "user_id,live_match_id,subscription_source")
                .execute()
#if DEBUG
            print("[RemoteNotificationDebug] favoriteSubscriptionSyncSucceeded count=\(rows.count) reason=\(reason)")
            if subscriptionSource == "favorite_team_auto" {
                print("[TeamAlertsDebug] autoSubscriptionCreated=\(rows.count) reason=\(reason)")
            }
#endif
        } catch {
#if DEBUG
            print("[RemoteNotificationDebug] favoriteSubscriptionSyncFailed count=\(rows.count) reason=\(reason) error=\(error.localizedDescription)")
#endif
        }
    }

    private func loadFavoriteTeamProGameAlertOverrides(
        for games: [FavoriteTeamProGame],
        userID: UUID,
        reason: String
    ) async {
        let liveMatchIDs = Array(Set(games.map(\.game.stableKey))).filter { !$0.isEmpty }
        guard !liveMatchIDs.isEmpty else { return }

        do {
            let rows: [FavoriteTeamProGameAlertOverrideRow] = try await supabase
                .from("pro_game_alert_subscriptions")
                .select("live_match_id,alert_override")
                .eq("user_id", value: userID.uuidString.lowercased())
                .eq("subscription_source", value: "favorite_team_auto")
                .in("live_match_id", values: liveMatchIDs)
                .execute()
                .value

            var next = favoriteTeamProGameAlertOverrides
            for row in rows {
                next[row.live_match_id] = FavoriteTeamProGameAlertOverride(rawValue: row.alert_override ?? "") ?? .inherit
            }
            favoriteTeamProGameAlertOverrides = next
#if DEBUG
            print("[TeamAlertsDebug] overridesLoaded=\(rows.count) reason=\(reason)")
#endif
        } catch {
#if DEBUG
            print("[TeamAlertsDebug] overridesLoaded=false reason=\(reason) error=\(error.localizedDescription)")
#endif
        }
    }

    private func syncFavoriteTeamProGameAlertOverride(
        _ override: FavoriteTeamProGameAlertOverride,
        for item: FavoriteTeamProGame,
        reason: String
    ) async {
        guard let userID = currentUserAuthId, isAuthenticatedForSocialFeatures else { return }
        let scoreAlertsEnabled = favoriteTeamProGameScoreUpdatesEnabled(for: item.game)
        let finalAlertsEnabled = scoreAlertsEnabled && notificationSettingsStore.proGameFinalScoreNotifications

        await upsertFavoriteTeamProGameSubscriptions(
            [item],
            userID: userID,
            reason: reason,
            subscriptionSource: "favorite_team_auto",
            scoreAlertsEnabledOverride: scoreAlertsEnabled,
            finalAlertsEnabledOverride: finalAlertsEnabled
        )
#if DEBUG
        print("[TeamAlertsDebug] overrideSynced=\(override.rawValue) id=\(item.game.stableKey) reason=\(reason)")
#endif
    }

    private func disableFavoriteTeamAutoDefaultSubscriptions(userID: UUID, reason: String) async {
        do {
            try await supabase
                .from("pro_game_alert_subscriptions")
                .update(FavoriteTeamAutoSubscriptionDisablePatch(
                    score_alerts_enabled: false,
                    final_score_alerts_enabled: false,
                    last_notified_scoreline: nil,
                    last_notified_status: nil
                ))
                .eq("user_id", value: userID.uuidString.lowercased())
                .eq("subscription_source", value: "favorite_team_auto")
                .neq("alert_override", value: FavoriteTeamProGameAlertOverride.on.rawValue)
                .execute()
#if DEBUG
            print("[TeamAlertsDebug] autoSubscriptionDisabled=true reason=\(reason)")
#endif
        } catch {
#if DEBUG
            print("[TeamAlertsDebug] autoSubscriptionDisabled=false reason=\(reason) error=\(error.localizedDescription)")
#endif
        }
    }

    private func favoriteTeamSubscriptionMatch(for game: SavedProGame) -> FavoriteTeamProGame? {
        if let match = favoriteTeamProGames.first(where: { $0.game.stableKey == game.stableKey }) {
            return match
        }
        if let match = businessFavoriteTeamProGames.first(where: { $0.game.stableKey == game.stableKey }) {
            return match
        }
        return nil
    }

    private func proGameScoreline(for game: SavedProGame) -> String {
        "\(game.scoreAway)-\(game.scoreHome)"
    }

    private func cleanedProGamePushValue(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct ProGameNotificationPreferenceUpsertRow: Encodable {
    let user_id: String
    let pro_game_reminder_notifications_enabled: Bool
    let pro_game_reminder_timing: String
    let pro_game_final_score_alerts_enabled: Bool
    let favorite_team_pro_game_alerts_enabled: Bool
}

private struct ProGameNotificationPreferenceRow: Decodable {
    let pro_game_reminder_notifications_enabled: Bool?
    let pro_game_reminder_timing: String?
    let pro_game_final_score_alerts_enabled: Bool?
    let favorite_team_pro_game_alerts_enabled: Bool?
}

private struct SavedProGameScoreAlertPatch: Encodable {
    let score_alerts_enabled: Bool
    let final_score_alerts_enabled: Bool
    let last_notified_scoreline: String?
    let score_alerts_updated_at: String
}

private struct FavoriteTeamProGameAlertSubscriptionUpsertRow: Encodable {
    let user_id: String
    let live_match_id: String
    let subscription_source: String
    let alert_override: String?
    let favorite_team_id: String
    let favorite_team_name: String
    let source: String?
    let external_id: String?
    let home_team: String
    let away_team: String
    let league: String?
    let sport: String?
    let start_time: String
    let match_status: String
    let score_home: Int
    let score_away: Int
    let score_alerts_enabled: Bool
    let final_score_alerts_enabled: Bool
    let last_notified_scoreline: String?
}

private struct FavoriteTeamProGameAlertOverrideRow: Decodable {
    let live_match_id: String
    let alert_override: String?
}

private struct FavoriteTeamAutoSubscriptionDisablePatch: Encodable {
    let score_alerts_enabled: Bool
    let final_score_alerts_enabled: Bool
    let last_notified_scoreline: String?
    let last_notified_status: String?
}
