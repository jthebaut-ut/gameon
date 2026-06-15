-- User-level Team Alerts for favorite-team Pro Games.

ALTER TABLE public.user_notification_preferences
  ADD COLUMN IF NOT EXISTS favorite_team_pro_game_alerts_enabled boolean NOT NULL DEFAULT false;

ALTER TABLE public.pro_game_alert_subscriptions
  DROP CONSTRAINT IF EXISTS pro_game_alert_subscriptions_subscription_source_check;

UPDATE public.pro_game_alert_subscriptions
SET subscription_source = 'favorite_team_auto'
WHERE subscription_source = 'favorite_team';

ALTER TABLE public.pro_game_alert_subscriptions
  ALTER COLUMN subscription_source SET DEFAULT 'manual';

ALTER TABLE public.pro_game_alert_subscriptions
  ADD CONSTRAINT pro_game_alert_subscriptions_subscription_source_check
  CHECK (subscription_source IN ('manual', 'favorite_team_auto'));

COMMENT ON COLUMN public.user_notification_preferences.favorite_team_pro_game_alerts_enabled IS
  'When true, backend Pro Game alert subscriptions are auto-maintained for games involving the user''s favorite teams.';

COMMENT ON COLUMN public.pro_game_alert_subscriptions.subscription_source IS
  'manual = user enabled an individual favorite-team game; favorite_team_auto = created by Team Alerts.';
