-- Fan saved professional games. These are user-owned snapshots so saved games
-- survive cache pruning in live_matches and still render after reinstall.

CREATE TABLE IF NOT EXISTS public.saved_pro_games (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  live_match_id text NOT NULL,
  source text,
  external_id text,
  home_team text NOT NULL,
  away_team text NOT NULL,
  league text,
  sport text,
  start_time timestamptz NOT NULL,
  match_status text,
  score_home integer,
  score_away integer,
  featured_event_slug text,
  tv_summary text,
  snapshot jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT saved_pro_games_user_live_match_unique UNIQUE (user_id, live_match_id)
);

CREATE INDEX IF NOT EXISTS idx_saved_pro_games_user_start_time
  ON public.saved_pro_games (user_id, start_time);

CREATE INDEX IF NOT EXISTS idx_saved_pro_games_user_created_at
  ON public.saved_pro_games (user_id, created_at DESC);

CREATE OR REPLACE FUNCTION public.saved_pro_games_touch_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS saved_pro_games_touch_updated_at_bu
  ON public.saved_pro_games;

CREATE TRIGGER saved_pro_games_touch_updated_at_bu
  BEFORE UPDATE ON public.saved_pro_games
  FOR EACH ROW
  EXECUTE FUNCTION public.saved_pro_games_touch_updated_at();

ALTER TABLE public.saved_pro_games ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS saved_pro_games_select_own
  ON public.saved_pro_games;
CREATE POLICY saved_pro_games_select_own
  ON public.saved_pro_games
  FOR SELECT
  TO authenticated
  USING (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS saved_pro_games_insert_own
  ON public.saved_pro_games;
CREATE POLICY saved_pro_games_insert_own
  ON public.saved_pro_games
  FOR INSERT
  TO authenticated
  WITH CHECK (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS saved_pro_games_update_own
  ON public.saved_pro_games;
CREATE POLICY saved_pro_games_update_own
  ON public.saved_pro_games
  FOR UPDATE
  TO authenticated
  USING (user_id = (SELECT auth.uid()))
  WITH CHECK (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS saved_pro_games_delete_own
  ON public.saved_pro_games;
CREATE POLICY saved_pro_games_delete_own
  ON public.saved_pro_games
  FOR DELETE
  TO authenticated
  USING (user_id = (SELECT auth.uid()));

GRANT SELECT, INSERT, UPDATE, DELETE ON public.saved_pro_games TO authenticated;
