-- Pickup game scheduled end time.
-- Older rows may have NULL end_time; clients fall back to game_start_at + 2 hours.

ALTER TABLE public.pickup_games
  ADD COLUMN IF NOT EXISTS end_time timestamptz;

CREATE INDEX IF NOT EXISTS pickup_games_end_time_idx
  ON public.pickup_games (end_time);

COMMENT ON COLUMN public.pickup_games.end_time IS
  'Optional scheduled end time for fan pickup games. NULL legacy rows are interpreted by clients as game_start_at + 2 hours.';
