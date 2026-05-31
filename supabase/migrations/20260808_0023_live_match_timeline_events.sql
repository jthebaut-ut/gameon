-- Cache optional TheSportsDB match timeline rows for live/upcoming matches.

ALTER TABLE public.live_matches
  ADD COLUMN IF NOT EXISTS timeline_events jsonb,
  ADD COLUMN IF NOT EXISTS timeline_updated_at timestamptz;

COMMENT ON COLUMN public.live_matches.timeline_events IS
  'Normalized TheSportsDB timeline rows for this event. Empty array means TheSportsDB returned no timeline rows during the last successful lookup.';

COMMENT ON COLUMN public.live_matches.timeline_updated_at IS
  'Timestamp of the last TheSportsDB timeline lookup for this live match external_id.';
