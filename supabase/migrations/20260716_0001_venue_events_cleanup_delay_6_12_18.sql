-- Venue events: allow 6 / 12 / 18 hour cleanup_delay_hours (generated purge_after_at unchanged).
-- Keeps 24 / 48 / 72 so existing rows remain valid until owners re-save retention.
-- No new columns; only relaxes CHECK on cleanup_delay_hours.

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'venue_events_cleanup_delay_hours_check'
  ) THEN
    ALTER TABLE public.venue_events DROP CONSTRAINT venue_events_cleanup_delay_hours_check;
  END IF;
  ALTER TABLE public.venue_events
    ADD CONSTRAINT venue_events_cleanup_delay_hours_check
    CHECK (cleanup_delay_hours IN (6, 12, 18, 24, 48, 72));
END $$;

COMMENT ON COLUMN public.venue_events.cleanup_delay_hours IS
  'Hours after scheduled_start_at when fan data may be purged (6, 12, 18 for new listings; legacy 24/48/72 still valid).';
