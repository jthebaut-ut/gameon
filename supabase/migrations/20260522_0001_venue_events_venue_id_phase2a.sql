-- Phase 2a: add nullable venue_id on venue_events as the transitional canonical link to public.venues.
-- No backfill, NOT NULL, RLS changes, or removal of owner_email / venue_name (see Phase 2b+).

ALTER TABLE public.venue_events
  ADD COLUMN IF NOT EXISTS venue_id uuid;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint c
    JOIN pg_class t ON c.conrelid = t.oid
    JOIN pg_namespace n ON t.relnamespace = n.oid
    WHERE n.nspname = 'public'
      AND t.relname = 'venue_events'
      AND c.conname = 'venue_events_venue_id_fkey'
  ) THEN
    ALTER TABLE public.venue_events
      ADD CONSTRAINT venue_events_venue_id_fkey
      FOREIGN KEY (venue_id)
      REFERENCES public.venues (id)
      ON DELETE SET NULL;
  END IF;
END $$;

COMMENT ON COLUMN public.venue_events.venue_id IS
  'Transitional canonical FK to public.venues.id. Nullable until backfill and client rollout; '
  'owner_email / venue_name remain legacy correlation fields. Prefer venue_id for new writes and reads once populated.';

-- Lookup and FK-friendly access by venue.
CREATE INDEX IF NOT EXISTS idx_venue_events_venue_id
  ON public.venue_events (venue_id);

-- Active rows only: fan/Discover-style filters (venue_id IN (...) + event_date range).
CREATE INDEX IF NOT EXISTS idx_venue_events_active_venue_id_event_date
  ON public.venue_events (venue_id, event_date)
  WHERE admin_status = 'active' AND venue_id IS NOT NULL;

-- Active rows: supports filters that lead on admin_status + event_date + venue_id (PostgREST / planner order varies).
CREATE INDEX IF NOT EXISTS idx_venue_events_active_admin_status_event_date_venue_id
  ON public.venue_events (admin_status, event_date, venue_id)
  WHERE admin_status = 'active' AND venue_id IS NOT NULL;
