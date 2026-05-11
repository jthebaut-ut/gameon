-- Phase 3a.1: read-only RPC for GameON calendar green dots (distinct dates only).
-- SECURITY INVOKER: callers see rows allowed by existing RLS on public.games / public.venue_events.
-- Does not alter RLS, tables, or prior migrations.

-- ---------------------------------------------------------------------------
-- Indexes (IF NOT EXISTS): support date-range + optional sport filters.
-- ---------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS idx_games_game_date_sport
  ON public.games (game_date, sport);

CREATE INDEX IF NOT EXISTS idx_venue_events_active_event_date_sport
  ON public.venue_events (event_date, sport)
  WHERE admin_status = 'active';

CREATE INDEX IF NOT EXISTS idx_venue_events_active_venue_id_event_date_sport
  ON public.venue_events (venue_id, event_date, sport)
  WHERE admin_status = 'active' AND venue_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- RPC: distinct calendar dates from official games + active venue events.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.gameon_calendar_dot_dates(
  p_date_min date,
  p_date_max date,
  p_sport text DEFAULT 'All',
  p_venue_ids uuid[] DEFAULT NULL,
  p_owner_emails text[] DEFAULT NULL,
  p_venue_names text[] DEFAULT NULL,
  p_region_only boolean DEFAULT false
)
RETURNS TABLE (event_date date)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  WITH params AS (
    SELECT
      p_date_min AS dmin,
      p_date_max AS dmax,
      NULLIF(trim(p_sport), '') AS sport_raw,
      p_venue_ids AS v_ids,
      p_owner_emails AS emails,
      p_venue_names AS vnames,
      p_region_only AS region_only
  ),
  sport AS (
    SELECT
      p.*,
      (p.sport_raw IS NULL OR lower(p.sport_raw) = 'all') AS skip_sport,
      p.sport_raw AS sport_exact
    FROM params p
  ),
  ids_nonempty AS (
    SELECT
      s.*,
      (s.v_ids IS NOT NULL AND cardinality(s.v_ids) > 0) AS has_venue_ids,
      (s.emails IS NOT NULL AND cardinality(s.emails) > 0) AS has_owner_emails,
      (s.vnames IS NOT NULL AND cardinality(s.vnames) > 0) AS has_venue_names
    FROM sport s
  ),
  official_dates AS (
    SELECT g.game_date::date AS d
    FROM public.games AS g
    CROSS JOIN ids_nonempty AS p
    WHERE g.game_date >= p.dmin
      AND g.game_date <= p.dmax
      AND (p.skip_sport OR g.sport = p.sport_exact)
  ),
  venue_dates AS (
    SELECT ve.event_date::date AS d
    FROM public.venue_events AS ve
    CROSS JOIN ids_nonempty AS p
    WHERE ve.admin_status = 'active'
      AND ve.event_date >= p.dmin
      AND ve.event_date <= p.dmax
      AND (p.skip_sport OR ve.sport = p.sport_exact)
      AND (
        NOT p.region_only
        OR (
          (p.has_venue_ids AND ve.venue_id IS NOT NULL AND ve.venue_id = ANY (p.v_ids))
          OR (
            ve.venue_id IS NULL
            AND (
              (p.has_owner_emails AND ve.owner_email IS NOT NULL AND ve.owner_email = ANY (p.emails))
              OR (p.has_venue_names AND ve.venue_name IS NOT NULL AND ve.venue_name = ANY (p.vnames))
            )
          )
        )
      )
  ),
  combined AS (
    SELECT d FROM official_dates
    UNION ALL
    SELECT d FROM venue_dates
  )
  SELECT DISTINCT c.d AS event_date
  FROM combined AS c
  WHERE c.d IS NOT NULL
  ORDER BY 1;
$$;

COMMENT ON FUNCTION public.gameon_calendar_dot_dates(
  date,
  date,
  text,
  uuid[],
  text[],
  text[],
  boolean
) IS
  'Phase 3a.1: read-only aggregation for GameON calendar dot dates. '
  'Returns distinct dates from public.games (official schedule) and active public.venue_events. '
  'Venue rows prefer venue_id = ANY(p_venue_ids) when p_region_only; legacy owner_email / venue_name '
  'match only rows with venue_id IS NULL. When p_region_only is false, all active venue_events in the '
  'date range qualify. Sport filter applies unless p_sport is null, empty, or All (case-insensitive). '
  'RLS unchanged; SECURITY INVOKER.';

GRANT EXECUTE ON FUNCTION public.gameon_calendar_dot_dates(
  date,
  date,
  text,
  uuid[],
  text[],
  text[],
  boolean
) TO anon;

GRANT EXECUTE ON FUNCTION public.gameon_calendar_dot_dates(
  date,
  date,
  text,
  uuid[],
  text[],
  text[],
  boolean
) TO authenticated;

GRANT EXECUTE ON FUNCTION public.gameon_calendar_dot_dates(
  date,
  date,
  text,
  uuid[],
  text[],
  text[],
  boolean
) TO service_role;
