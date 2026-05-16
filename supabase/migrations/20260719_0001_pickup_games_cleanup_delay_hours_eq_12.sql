-- Pickup games: enforce 12h retention (cleanup_delay_hours = 12, remove_after_at = game_start_at + 12h).
-- Idempotent repair for databases that partially applied an older ordering (CHECK before bulk UPDATE),
-- or still have legacy CHECK / row values. Safe to rerun.
-- Does not touch venue_events.
--
-- ORDER: DROP CHECK → trigger → UPDATE ALL rows → ADD CHECK (same as 20260717_0001).

-- 1) Drop CHECK first (allows rewriting legacy values without violating the old rule).
ALTER TABLE public.pickup_games
  DROP CONSTRAINT IF EXISTS pickup_games_cleanup_delay_hours_check;

-- 2) Trigger function + trigger
CREATE OR REPLACE FUNCTION public.pickup_games_set_remove_after_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.cleanup_delay_hours := 12;
  NEW.remove_after_at := NEW.game_start_at + interval '12 hours';
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.pickup_games_set_remove_after_at() IS
  'Forces cleanup_delay_hours=12 and remove_after_at=game_start_at+12h on every INSERT/UPDATE to pickup_games.';

DROP TRIGGER IF EXISTS pickup_games_remove_after_biub ON public.pickup_games;
CREATE TRIGGER pickup_games_remove_after_biub
  BEFORE INSERT OR UPDATE ON public.pickup_games
  FOR EACH ROW
  EXECUTE FUNCTION public.pickup_games_set_remove_after_at();

-- 3) Normalize ALL rows (every status; NULL cleanup_delay_hours; drifted remove_after_at).
UPDATE public.pickup_games
SET
  cleanup_delay_hours = 12,
  remove_after_at = game_start_at + interval '12 hours';

-- 4) ADD CONSTRAINT only after normalization (idempotent if already present).
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint c
    JOIN pg_class t ON t.oid = c.conrelid
    JOIN pg_namespace n ON n.oid = t.relnamespace
    WHERE n.nspname = 'public'
      AND t.relname = 'pickup_games'
      AND c.conname = 'pickup_games_cleanup_delay_hours_check'
  ) THEN
    ALTER TABLE public.pickup_games
      ADD CONSTRAINT pickup_games_cleanup_delay_hours_check
      CHECK (cleanup_delay_hours = 12);
  END IF;
END $$;

COMMENT ON COLUMN public.pickup_games.cleanup_delay_hours IS
  'Pickup auto-removal delay in hours; must be 12 (remove_after_at = game_start_at + 12h). Not configurable in the app.';

-- Verification: SELECT DISTINCT cleanup_delay_hours FROM public.pickup_games;  → expect 12 only (empty table OK).
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.pickup_games
    WHERE cleanup_delay_hours IS DISTINCT FROM 12
  ) THEN
    RAISE EXCEPTION
      'pickup_games_cleanup_delay_hours verification failed: expected only 12 (see SELECT DISTINCT cleanup_delay_hours FROM pickup_games)';
  END IF;
END $$;
