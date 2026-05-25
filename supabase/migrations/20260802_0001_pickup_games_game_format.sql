-- Persist the lightweight game format for pickup_games without changing the table name.

ALTER TABLE public.pickup_games
  ADD COLUMN IF NOT EXISTS game_format text NOT NULL DEFAULT 'pickup';

UPDATE public.pickup_games
SET game_format = lower(trim(both from game_format))
WHERE game_format IS NOT NULL;

UPDATE public.pickup_games
SET game_format = 'pickup'
WHERE game_format IS NULL
   OR trim(both from game_format) = ''
   OR game_format NOT IN ('pickup', 'practice', 'scrimmage');

ALTER TABLE public.pickup_games
  ALTER COLUMN game_format SET DEFAULT 'pickup';

ALTER TABLE public.pickup_games
  ALTER COLUMN game_format SET NOT NULL;

ALTER TABLE public.pickup_games DROP CONSTRAINT IF EXISTS pickup_games_game_format_check;

ALTER TABLE public.pickup_games
  ADD CONSTRAINT pickup_games_game_format_check
  CHECK (game_format IN ('pickup', 'practice', 'scrimmage'));

COMMENT ON COLUMN public.pickup_games.game_format IS
  'Lightweight format for community games: pickup | practice | scrimmage.';
