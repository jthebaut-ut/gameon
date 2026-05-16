-- Pickup games: fixed 12h retention (cleanup_delay_hours = 12, remove_after_at = game_start_at + 12h).
-- Tightens CHECK from IN (12, 24) / legacy =24-only so inserts/updates cannot violate 12h policy.
--
-- ORDER (required): legacy CHECK can forbid rewriting rows (e.g. =24 only while bulk-setting 12).
--   1) DROP existing pickup_games_cleanup_delay_hours_check
--   2) CREATE OR REPLACE trigger function + trigger
--   3) UPDATE ALL rows (every status; do not skip removed/expired/archived-style rows; NULLs normalized)
--   4) ADD CONSTRAINT only after normalization
-- Idempotent / safe to rerun.

-- ---------------------------------------------------------------------------
-- 1) Drop CHECK first so any legacy cleanup_delay_hours / remove_after_at can be updated freely.
-- ---------------------------------------------------------------------------
ALTER TABLE public.pickup_games
  DROP CONSTRAINT IF EXISTS pickup_games_cleanup_delay_hours_check;

-- ---------------------------------------------------------------------------
-- 2) Trigger function + trigger (defense in depth on every INSERT/UPDATE).
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- 3) Normalize ALL existing rows (no filter on status: active, removed, expired, archived, completed, etc.).
--    Sets NULL cleanup_delay_hours to 12; recomputes remove_after_at from game_start_at + 12h.
-- ---------------------------------------------------------------------------
UPDATE public.pickup_games
SET
  cleanup_delay_hours = 12,
  remove_after_at = game_start_at + interval '12 hours';

-- ---------------------------------------------------------------------------
-- 4) Enforce CHECK only after every row carries cleanup_delay_hours = 12.
-- ---------------------------------------------------------------------------
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

COMMENT ON FUNCTION public.purge_expired_pickup_games() IS
  'Deletes pickup_games past remove_after_at (game_start_at + 12h). Join requests cascade. Run on a schedule with service_role.';

-- ---------------------------------------------------------------------------
-- 5) Verification (manual): SELECT DISTINCT cleanup_delay_hours FROM public.pickup_games;
--    Expected: single value 12 (empty table is OK).
-- ---------------------------------------------------------------------------
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
