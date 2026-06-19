-- Persist Pro Game kickoff reminder timing in user notification preferences.

ALTER TABLE public.user_notification_preferences
  ADD COLUMN IF NOT EXISTS pro_game_reminder_timing text NOT NULL DEFAULT 'oneHour'
    CHECK (
      pro_game_reminder_timing IN (
        'never',
        'oneDay',
        'oneHour',
        'thirtyMinutes',
        'tenMinutes'
      )
    );

COMMENT ON COLUMN public.user_notification_preferences.pro_game_reminder_timing IS
  'When FanGeo should schedule local kickoff reminders for saved Pro Games.';

UPDATE public.user_notification_preferences
SET pro_game_reminder_timing = CASE
  WHEN pro_game_reminder_notifications_enabled = false THEN 'never'
  ELSE pro_game_reminder_timing
END
WHERE pro_game_reminder_notifications_enabled = false
  AND pro_game_reminder_timing <> 'never';
