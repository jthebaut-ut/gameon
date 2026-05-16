-- Pickup games: default auto-removal at game_start_at + 12h for new writes (trigger).
-- Does not bulk-update existing rows; legacy rows may still have cleanup_delay_hours=24 until edited.
-- Purge still uses remove_after_at <= now().

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
  'Forces cleanup_delay_hours=12 and remove_after_at=game_start_at+12h on INSERT/UPDATE. Legacy rows may retain 24 until updated.';

DROP TRIGGER IF EXISTS pickup_games_remove_after_biub ON public.pickup_games;
CREATE TRIGGER pickup_games_remove_after_biub
  BEFORE INSERT OR UPDATE ON public.pickup_games
  FOR EACH ROW
  EXECUTE FUNCTION public.pickup_games_set_remove_after_at();

ALTER TABLE public.pickup_games
  DROP CONSTRAINT IF EXISTS pickup_games_cleanup_delay_hours_check;

-- Allow 24 while legacy rows exist without a backfill; new/edited rows get 12 from the trigger.
ALTER TABLE public.pickup_games
  ADD CONSTRAINT pickup_games_cleanup_delay_hours_check
  CHECK (cleanup_delay_hours IN (12, 24));

COMMENT ON FUNCTION public.purge_expired_pickup_games() IS
  'Deletes pickup_games past remove_after_at. Join requests cascade. Scheduled purge unchanged.';
