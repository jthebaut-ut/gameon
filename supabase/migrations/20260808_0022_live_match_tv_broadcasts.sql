-- Cache TheSportsDB TV broadcast rows alongside live/upcoming matches.

ALTER TABLE public.live_matches
  ADD COLUMN IF NOT EXISTS tv_broadcasts jsonb,
  ADD COLUMN IF NOT EXISTS tv_updated_at timestamptz;

COMMENT ON COLUMN public.live_matches.tv_broadcasts IS
  'Normalized TheSportsDB TV broadcast rows for this event. Empty array means TheSportsDB returned no TV rows during the last successful TV lookup.';

COMMENT ON COLUMN public.live_matches.tv_updated_at IS
  'Timestamp of the last TV broadcast lookup for this live match external_id.';
