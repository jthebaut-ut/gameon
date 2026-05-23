-- Expired Game/Social Cleanup Phase 2C.
--
-- Scheduling only. This migration adds the cleanup-ready index and schedules
-- the Phase 2B safe cleanup function hourly. It does not modify cleanup logic
-- and does not schedule or call the legacy venue-event purge function.

CREATE INDEX IF NOT EXISTS idx_venue_events_cleanup_ready
ON public.venue_events (purge_after_at)
WHERE purged_at IS NULL;

CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA extensions;

DO $$
DECLARE
  legacy_job record;
BEGIN
  FOR legacy_job IN
    SELECT jobid
    FROM cron.job
    WHERE command ILIKE '%purge_expired_venue_events%'
  LOOP
    PERFORM cron.unschedule(legacy_job.jobid);
  END LOOP;
END $$;

SELECT cron.unschedule('fangeo_expired_game_social_cleanup_hourly')
WHERE EXISTS (
  SELECT 1
  FROM cron.job
  WHERE jobname = 'fangeo_expired_game_social_cleanup_hourly'
);

SELECT cron.schedule(
  'fangeo_expired_game_social_cleanup_hourly',
  '0 * * * *',
  $$
    SELECT public.cleanup_expired_game_social_phase2(
      p_now := now(),
      p_limit := 500,
      p_dry_run := false
    );
  $$
);
