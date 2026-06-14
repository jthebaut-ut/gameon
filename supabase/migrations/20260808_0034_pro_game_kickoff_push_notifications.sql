-- Backend kickoff/start push support for saved Pro Games.

ALTER TABLE public.user_notification_preferences
  ADD COLUMN IF NOT EXISTS pro_game_reminder_notifications_enabled boolean NOT NULL DEFAULT true;

ALTER TABLE public.pro_game_score_notification_deliveries
  DROP CONSTRAINT IF EXISTS pro_game_score_notification_deliveries_notification_type_check;

ALTER TABLE public.pro_game_score_notification_deliveries
  ADD CONSTRAINT pro_game_score_notification_deliveries_notification_type_check
  CHECK (notification_type IN ('kickoff', 'score', 'final'));

COMMENT ON TABLE public.pro_game_score_notification_deliveries IS
  'Dedupe ledger for closed-app Pro Game kickoff, score, and final push notifications.';
