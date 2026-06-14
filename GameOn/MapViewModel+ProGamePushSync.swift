import Foundation
import Supabase

extension MapViewModel {
    func syncProGameFinalScorePreferenceToBackend(reason: String) async {
        guard let userID = currentUserAuthId, isAuthenticatedForSocialFeatures else { return }
        let row = ProGameNotificationPreferenceUpsertRow(
            user_id: userID.uuidString.lowercased(),
            pro_game_reminder_notifications_enabled: notificationSettingsStore.proGameReminderNotifications,
            pro_game_final_score_alerts_enabled: notificationSettingsStore.proGameFinalScoreNotifications
        )

        do {
            try await supabase
                .from("user_notification_preferences")
                .upsert(row, onConflict: "user_id")
                .execute()
#if DEBUG
            print("[RemoteNotificationDebug] proGamePreferenceSyncSucceeded reminders=\(row.pro_game_reminder_notifications_enabled) final=\(row.pro_game_final_score_alerts_enabled) reason=\(reason)")
#endif
        } catch {
#if DEBUG
            print("[RemoteNotificationDebug] proGamePreferenceSyncFailed reason=\(reason) error=\(error.localizedDescription)")
#endif
        }
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
        await upsertFavoriteTeamProGameSubscriptions([favoriteTeamGame], userID: userID, reason: "scoreAlertToggle")
    }

    func syncFavoriteTeamProGameSubscriptions(_ games: [FavoriteTeamProGame], reason: String) async {
        guard let userID = currentUserAuthId, isAuthenticatedForSocialFeatures else { return }
        await upsertFavoriteTeamProGameSubscriptions(games, userID: userID, reason: reason)
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

    private func upsertFavoriteTeamProGameSubscriptions(_ games: [FavoriteTeamProGame], userID: UUID, reason: String) async {
        let rows = games.map { item in
            let game = item.game
            let scoreAlertsEnabled = favoriteTeamProGameScoreUpdatesEnabled(for: game)
            return FavoriteTeamProGameAlertSubscriptionUpsertRow(
                user_id: userID.uuidString.lowercased(),
                live_match_id: game.stableKey,
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
                final_score_alerts_enabled: notificationSettingsStore.proGameFinalScoreNotifications,
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
#endif
        } catch {
#if DEBUG
            print("[RemoteNotificationDebug] favoriteSubscriptionSyncFailed count=\(rows.count) reason=\(reason) error=\(error.localizedDescription)")
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
    let pro_game_final_score_alerts_enabled: Bool
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
    let subscription_source: String = "favorite_team"
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
