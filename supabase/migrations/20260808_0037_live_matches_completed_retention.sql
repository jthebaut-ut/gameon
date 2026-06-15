-- Keep recently completed Pro Games available long enough for saved-game hydration.

CREATE OR REPLACE FUNCTION public.prune_live_matches_cache(
  window_start timestamptz DEFAULT now() - interval '24 hours',
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
      lm.match_status = 'FT'
      AND lm.updated_at >= now() - interval '24 hours'
    )
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

DROP POLICY IF EXISTS live_matches_select_public_recent
  ON public.live_matches;
CREATE POLICY live_matches_select_public_recent
  ON public.live_matches
  FOR SELECT
  TO anon, authenticated
  USING (
    (
      start_time >= (now() - interval '24 hours')
      AND start_time <= (now() + interval '7 days')
    )
    OR (
      match_status = 'FT'
      AND updated_at >= now() - interval '24 hours'
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

COMMENT ON FUNCTION public.prune_live_matches_cache(timestamptz, timestamptz) IS
  'Prunes live_matches outside the active window while retaining recently completed FT rows for saved Pro Game hydration.';
