-- Per-game overrides for favorite-team auto Team Alerts.

ALTER TABLE public.pro_game_alert_subscriptions
  ADD COLUMN IF NOT EXISTS alert_override text NOT NULL DEFAULT 'inherit';

ALTER TABLE public.pro_game_alert_subscriptions
  DROP CONSTRAINT IF EXISTS pro_game_alert_subscriptions_alert_override_check;

ALTER TABLE public.pro_game_alert_subscriptions
  ADD CONSTRAINT pro_game_alert_subscriptions_alert_override_check
  CHECK (alert_override IN ('inherit', 'on', 'off', 'muted'));

CREATE INDEX IF NOT EXISTS idx_pro_game_alert_subscriptions_auto_override
  ON public.pro_game_alert_subscriptions (user_id, live_match_id, alert_override)
  WHERE subscription_source = 'favorite_team_auto';

COMMENT ON COLUMN public.pro_game_alert_subscriptions.alert_override IS
  'Per-game Team Alerts override for favorite_team_auto rows. inherit follows favorite_team_pro_game_alerts_enabled; on enables one game; off/muted suppress kickoff, score, and final pushes.';
