-- Bounded live sports cache normalized by the sync-live-matches Edge Function.
-- App clients read this table; external sports API keys and writes stay server-side.

CREATE TABLE IF NOT EXISTS public.live_matches (
  id text PRIMARY KEY,
  source text NOT NULL DEFAULT 'api-football',
  external_id text NOT NULL,
  sport text NOT NULL,
  home_team text NOT NULL,
  away_team text NOT NULL,
  score_home integer NOT NULL DEFAULT 0 CHECK (score_home >= 0),
  score_away integer NOT NULL DEFAULT 0 CHECK (score_away >= 0),
  match_status text NOT NULL CHECK (match_status IN ('LIVE', 'HT', 'FT', 'SCHEDULED')),
  minute integer CHECK (minute IS NULL OR minute >= 0),
  league text NOT NULL,
  start_time timestamptz NOT NULL,
  payload jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_live_matches_status_start_time
  ON public.live_matches (match_status, start_time);

CREATE INDEX IF NOT EXISTS idx_live_matches_start_time
  ON public.live_matches (start_time);

CREATE INDEX IF NOT EXISTS idx_live_matches_source_external
  ON public.live_matches (source, external_id);

CREATE INDEX IF NOT EXISTS idx_live_matches_updated_at
  ON public.live_matches (updated_at);

CREATE OR REPLACE FUNCTION public.live_matches_touch_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS live_matches_touch_updated_at ON public.live_matches;
CREATE TRIGGER live_matches_touch_updated_at
  BEFORE UPDATE ON public.live_matches
  FOR EACH ROW
  EXECUTE FUNCTION public.live_matches_touch_updated_at();

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
  DELETE FROM public.live_matches
  WHERE start_time < window_start
     OR start_time > window_end;

  GET DIAGNOSTICS deleted_count = ROW_COUNT;
  RETURN deleted_count;
END;
$$;

REVOKE ALL ON FUNCTION public.prune_live_matches_cache(timestamptz, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.prune_live_matches_cache(timestamptz, timestamptz) TO service_role;

ALTER TABLE public.live_matches ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS live_matches_select_public_recent ON public.live_matches;
CREATE POLICY live_matches_select_public_recent
  ON public.live_matches
  FOR SELECT
  TO anon, authenticated
  USING (
    start_time >= (now() - interval '2 hours')
    AND start_time <= (now() + interval '7 days')
  );

REVOKE INSERT, UPDATE, DELETE ON public.live_matches FROM anon;
REVOKE INSERT, UPDATE, DELETE ON public.live_matches FROM authenticated;
GRANT SELECT ON public.live_matches TO anon;
GRANT SELECT ON public.live_matches TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.live_matches TO service_role;

COMMENT ON TABLE public.live_matches IS
  'Short-lived live/upcoming sports cache populated by sync-live-matches for now - 2 hours through now + 7 days; clients have read-only access.';
