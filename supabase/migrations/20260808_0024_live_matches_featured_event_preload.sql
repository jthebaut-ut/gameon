-- Preserve and expose scheduled fixtures tied to active/upcoming featured events
-- without widening the normal live_matches cache window for every league.

ALTER TABLE public.live_matches
  ADD COLUMN IF NOT EXISTS featured_event_slug text;

CREATE INDEX IF NOT EXISTS idx_live_matches_featured_event_start_time
  ON public.live_matches (featured_event_slug, start_time)
  WHERE featured_event_slug IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_live_matches_sport_start_time
  ON public.live_matches (sport, start_time);

CREATE INDEX IF NOT EXISTS idx_live_matches_league_start_time
  ON public.live_matches (league, start_time);

CREATE INDEX IF NOT EXISTS idx_live_matches_source_start_time
  ON public.live_matches (source, start_time);

COMMENT ON COLUMN public.live_matches.featured_event_slug IS
  'Featured event slug that caused this scheduled fixture to be preloaded. Null for normal live/upcoming cache rows.';

COMMENT ON TABLE public.live_matches IS
  'Bounded sports cache populated by sync-live-matches. Normal rows are kept near live/upcoming time; scheduled featured event fixtures may be preserved for active/upcoming featured event windows.';

CREATE OR REPLACE FUNCTION public.prune_live_matches_cache(
  window_start timestamptz DEFAULT now() - interval '2 hours',
  window_end timestamptz DEFAULT now() + interval '7 days'
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  deleted_count integer;
BEGIN
  DELETE FROM public.live_matches lm
  WHERE (lm.start_time < window_start OR lm.start_time > window_end)
    AND NOT (
      lm.match_status = 'SCHEDULED'
      AND lm.featured_event_slug IS NOT NULL
      AND EXISTS (
        SELECT 1
        FROM public.featured_events fe
        WHERE fe.slug = lm.featured_event_slug
          AND fe.enabled = true
          AND fe.end_date >= current_date
          AND fe.start_date <= (current_date + interval '180 days')::date
          AND lm.start_time::date BETWEEN fe.start_date AND fe.end_date
      )
    );

  GET DIAGNOSTICS deleted_count = ROW_COUNT;
  RETURN deleted_count;
END;
$$;

REVOKE ALL ON FUNCTION public.prune_live_matches_cache(timestamptz, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.prune_live_matches_cache(timestamptz, timestamptz) TO service_role;

DROP POLICY IF EXISTS live_matches_select_public_recent ON public.live_matches;
CREATE POLICY live_matches_select_public_recent
  ON public.live_matches
  FOR SELECT
  TO anon, authenticated
  USING (
    (
      start_time >= (now() - interval '2 hours')
      AND start_time <= (now() + interval '7 days')
    )
    OR (
      match_status = 'SCHEDULED'
      AND featured_event_slug IS NOT NULL
      AND EXISTS (
        SELECT 1
        FROM public.featured_events fe
        WHERE fe.slug = featured_event_slug
          AND fe.enabled = true
          AND fe.end_date >= current_date
          AND fe.start_date <= (current_date + interval '180 days')::date
          AND start_time::date BETWEEN fe.start_date AND fe.end_date
      )
    )
  );
