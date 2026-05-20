-- Business venue game import metadata for live/API game picks.
-- Existing manual venue_events rows remain valid; all new metadata is nullable
-- except imported_from_api, which safely defaults to false.

ALTER TABLE public.venue_events
  ADD COLUMN IF NOT EXISTS external_game_id text,
  ADD COLUMN IF NOT EXISTS external_source text,
  ADD COLUMN IF NOT EXISTS imported_from_api boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS external_league text;

CREATE INDEX IF NOT EXISTS idx_venue_events_external_game_lookup
  ON public.venue_events (venue_id, event_date, external_source, external_game_id)
  WHERE external_game_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_venue_events_unique_external_game_per_venue_day
  ON public.venue_events (venue_id, event_date, external_source, external_game_id)
  WHERE external_game_id IS NOT NULL
    AND COALESCE(admin_status, 'active') = 'active';

CREATE UNIQUE INDEX IF NOT EXISTS idx_venue_events_unique_external_game_per_owner_day
  ON public.venue_events (owner_email, event_date, external_source, external_game_id)
  WHERE venue_id IS NULL
    AND external_game_id IS NOT NULL
    AND COALESCE(admin_status, 'active') = 'active';

COMMENT ON COLUMN public.venue_events.external_game_id IS
  'Provider game/match id when a business imports a venue game from the live games API.';
COMMENT ON COLUMN public.venue_events.external_source IS
  'Provider/source for imported venue game metadata, e.g. supabase:live_matches.';
COMMENT ON COLUMN public.venue_events.imported_from_api IS
  'True when a business venue game was seeded from an external live/API game and then reviewed/saved.';
COMMENT ON COLUMN public.venue_events.external_league IS
  'League or competition label from the external provider.';
