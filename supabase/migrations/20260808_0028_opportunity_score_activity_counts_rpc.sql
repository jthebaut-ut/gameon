-- Extend Business Suggested Games aggregate demand counts.
-- Returns only per-live-match aggregate counts; never exposes user identities.

CREATE INDEX IF NOT EXISTS idx_venue_events_imported_external_game_id
  ON public.venue_events (external_game_id)
  WHERE imported_from_api = true
    AND external_game_id IS NOT NULL
    AND COALESCE(admin_status, 'active') = 'active';

DROP FUNCTION IF EXISTS public.get_saved_pro_game_counts(text[], jsonb);
DROP FUNCTION IF EXISTS public.get_saved_pro_game_counts(text[]);

CREATE OR REPLACE FUNCTION public.get_saved_pro_game_counts(
  p_live_match_ids text[],
  p_team_ids_by_live_match jsonb DEFAULT '{}'::jsonb
)
RETURNS TABLE (
  live_match_id text,
  saved_count integer,
  going_count integer,
  team_follow_count integer
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
  WITH requested AS (
    SELECT DISTINCT btrim(match_id) AS live_match_id
    FROM unnest(COALESCE(p_live_match_ids, ARRAY[]::text[])) AS match_id
    WHERE btrim(match_id) <> ''
  ),
  saved_counts AS (
    SELECT
      r.live_match_id,
      COUNT(*)::integer AS saved_count
    FROM requested r
    JOIN public.saved_pro_games spg
      ON spg.live_match_id = r.live_match_id
    GROUP BY r.live_match_id
  ),
  hosted_counts AS (
    SELECT
      r.live_match_id,
      COUNT(DISTINCT NULLIF(lower(btrim(i.user_email)), ''))::integer AS going_count
    FROM requested r
    JOIN public.venue_events ve
      ON btrim(COALESCE(ve.external_game_id, '')) = r.live_match_id
     AND COALESCE(ve.imported_from_api, false) = true
     AND COALESCE(ve.admin_status, 'active') = 'active'
    JOIN public.venue_event_interests i
      ON i.venue_event_id = ve.id
     AND COALESCE(i.interest_status, 'going') IN ('going', 'interested')
    GROUP BY r.live_match_id
  ),
  team_inputs AS (
    SELECT DISTINCT
      r.live_match_id,
      btrim(team_id) AS team_id
    FROM requested r
    CROSS JOIN LATERAL jsonb_array_elements_text(
      CASE
        WHEN jsonb_typeof(COALESCE(p_team_ids_by_live_match, '{}'::jsonb) -> r.live_match_id) = 'array'
          THEN COALESCE(p_team_ids_by_live_match, '{}'::jsonb) -> r.live_match_id
        ELSE '[]'::jsonb
      END
    ) AS team_id
    WHERE btrim(team_id) <> ''
  ),
  team_counts AS (
    SELECT
      ti.live_match_id,
      COUNT(DISTINCT uft.user_id)::integer AS team_follow_count
    FROM team_inputs ti
    JOIN public.user_favorite_teams uft
      ON uft.team_id = ti.team_id
    GROUP BY ti.live_match_id
  )
  SELECT
    r.live_match_id,
    COALESCE(sc.saved_count, 0)::integer AS saved_count,
    COALESCE(hc.going_count, 0)::integer AS going_count,
    COALESCE(tc.team_follow_count, 0)::integer AS team_follow_count
  FROM requested r
  LEFT JOIN saved_counts sc
    ON sc.live_match_id = r.live_match_id
  LEFT JOIN hosted_counts hc
    ON hc.live_match_id = r.live_match_id
  LEFT JOIN team_counts tc
    ON tc.live_match_id = r.live_match_id;
$$;

REVOKE ALL ON FUNCTION public.get_saved_pro_game_counts(text[], jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_saved_pro_game_counts(text[], jsonb) TO authenticated;
