-- Shareable favorite teams for public profile previews (catalog team_id strings only).

CREATE TABLE IF NOT EXISTS public.user_favorite_teams (
  user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  team_id text NOT NULL CHECK (char_length(trim(team_id)) > 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, team_id)
);

CREATE INDEX IF NOT EXISTS idx_user_favorite_teams_user_created
  ON public.user_favorite_teams (user_id, created_at);

ALTER TABLE public.user_favorite_teams ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS user_favorite_teams_select_authenticated ON public.user_favorite_teams;
CREATE POLICY user_favorite_teams_select_authenticated
  ON public.user_favorite_teams FOR SELECT TO authenticated
  USING (true);

DROP POLICY IF EXISTS user_favorite_teams_insert_own ON public.user_favorite_teams;
CREATE POLICY user_favorite_teams_insert_own
  ON public.user_favorite_teams FOR INSERT TO authenticated
  WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS user_favorite_teams_update_own ON public.user_favorite_teams;
CREATE POLICY user_favorite_teams_update_own
  ON public.user_favorite_teams FOR UPDATE TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS user_favorite_teams_delete_own ON public.user_favorite_teams;
CREATE POLICY user_favorite_teams_delete_own
  ON public.user_favorite_teams FOR DELETE TO authenticated
  USING (user_id = auth.uid());

GRANT SELECT, INSERT, UPDATE, DELETE ON public.user_favorite_teams TO authenticated;

COMMENT ON TABLE public.user_favorite_teams IS
  'Fan-selected catalog team_id values for profile identity; readable by authenticated users for public previews.';
