-- New saved Pro Games should opt into Live Score Alerts by default.
-- Existing rows keep their current per-game score_alerts_enabled value.

ALTER TABLE public.saved_pro_games
  ALTER COLUMN score_alerts_enabled SET DEFAULT true;
