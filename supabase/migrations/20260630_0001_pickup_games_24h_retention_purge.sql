-- Pickup games: fixed 24h post-start auto-removal, hard-delete purge, and verified CASCADE on join requests.
-- Schedule `public.purge_expired_pickup_games()` via Supabase Dashboard → Database → Cron or Edge Function (service_role),
-- same pattern as `purge_expired_venue_events()`. Manual: SELECT public.purge_expired_pickup_games();

-- ---------------------------------------------------------------------------
-- 1) Always 24h retention + remove_after_at = game_start_at + 24h (ignore client cleanup_delay_hours)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.pickup_games_set_remove_after_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.cleanup_delay_hours := 24;
  NEW.remove_after_at := NEW.game_start_at + interval '24 hours';
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS pickup_games_remove_after_biub ON public.pickup_games;
CREATE TRIGGER pickup_games_remove_after_biub
  BEFORE INSERT OR UPDATE ON public.pickup_games
  FOR EACH ROW
  EXECUTE FUNCTION public.pickup_games_set_remove_after_at();

COMMENT ON FUNCTION public.pickup_games_set_remove_after_at() IS
  'Forces cleanup_delay_hours=24 and remove_after_at=game_start_at+24h on every write.';

ALTER TABLE public.pickup_games
  DROP CONSTRAINT IF EXISTS pickup_games_cleanup_delay_hours_check;

ALTER TABLE public.pickup_games
  ADD CONSTRAINT pickup_games_cleanup_delay_hours_check
  CHECK (cleanup_delay_hours = 24);

UPDATE public.pickup_games
SET
  cleanup_delay_hours = 24,
  remove_after_at = game_start_at + interval '24 hours';

-- ---------------------------------------------------------------------------
-- 2) Hard-delete expired rows (CASCADE removes pickup_game_requests, etc.)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.purge_expired_pickup_games()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  deleted_count integer;
BEGIN
  DELETE FROM public.pickup_games pg
  WHERE pg.remove_after_at IS NOT NULL
    AND pg.remove_after_at <= now();

  GET DIAGNOSTICS deleted_count = ROW_COUNT;
  RETURN deleted_count;
END;
$$;

COMMENT ON FUNCTION public.purge_expired_pickup_games() IS
  'Deletes pickup_games past remove_after_at (start + 24h). Join requests cascade. Run on a schedule with service_role.';

REVOKE ALL ON FUNCTION public.purge_expired_pickup_games() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.purge_expired_pickup_games() TO service_role;

CREATE INDEX IF NOT EXISTS idx_pickup_games_remove_after_purge
  ON public.pickup_games (remove_after_at)
  WHERE remove_after_at IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 3) Ensure join requests FK uses ON DELETE CASCADE (idempotent for standard PG name)
-- ---------------------------------------------------------------------------
ALTER TABLE public.pickup_game_requests
  DROP CONSTRAINT IF EXISTS pickup_game_requests_pickup_game_id_fkey;

ALTER TABLE public.pickup_game_requests
  ADD CONSTRAINT pickup_game_requests_pickup_game_id_fkey
  FOREIGN KEY (pickup_game_id)
  REFERENCES public.pickup_games (id)
  ON DELETE CASCADE;
