-- Fan-created pickup games (phase 1). Venue/business games unchanged.

CREATE TABLE public.pickup_games (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  creator_user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  creator_email text,
  title text NOT NULL,
  sport text NOT NULL,
  description text,
  skill_level text CHECK (skill_level IS NULL OR skill_level IN ('beginner', 'intermediate', 'expert', 'any')),
  game_start_at timestamptz NOT NULL,
  address text,
  city text,
  state text,
  latitude double precision,
  longitude double precision,
  is_visible boolean NOT NULL DEFAULT true,
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'removed', 'expired')),
  cleanup_delay_hours integer NOT NULL DEFAULT 24 CHECK (cleanup_delay_hours IN (24, 48, 72)),
  remove_after_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX pickup_games_sport_game_start_at_idx ON public.pickup_games (sport, game_start_at);
CREATE INDEX pickup_games_status_is_visible_idx ON public.pickup_games (status, is_visible);

CREATE OR REPLACE FUNCTION public.pickup_games_set_remove_after_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.remove_after_at := NEW.game_start_at + make_interval(hours => NEW.cleanup_delay_hours);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS pickup_games_remove_after_biub ON public.pickup_games;
CREATE TRIGGER pickup_games_remove_after_biub
  BEFORE INSERT OR UPDATE OF game_start_at, cleanup_delay_hours ON public.pickup_games
  FOR EACH ROW
  EXECUTE FUNCTION public.pickup_games_set_remove_after_at();

CREATE OR REPLACE FUNCTION public.pickup_games_touch_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS pickup_games_touch_updated_at ON public.pickup_games;
CREATE TRIGGER pickup_games_touch_updated_at
  BEFORE UPDATE ON public.pickup_games
  FOR EACH ROW
  EXECUTE FUNCTION public.pickup_games_touch_updated_at();

ALTER TABLE public.pickup_games ENABLE ROW LEVEL SECURITY;

-- Public listing: active, visible, not past cleanup window. Creators always see their own rows (incl. hidden / soft-deleted).
DROP POLICY IF EXISTS pickup_games_select_authenticated ON public.pickup_games;
CREATE POLICY pickup_games_select_authenticated
  ON public.pickup_games
  FOR SELECT
  TO authenticated
  USING (
    creator_user_id = (SELECT auth.uid())
    OR (
      status = 'active'
      AND is_visible
      AND remove_after_at IS NOT NULL
      AND remove_after_at > now()
    )
  );

DROP POLICY IF EXISTS pickup_games_insert_creator_only ON public.pickup_games;
CREATE POLICY pickup_games_insert_creator_only
  ON public.pickup_games
  FOR INSERT
  TO authenticated
  WITH CHECK (creator_user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS pickup_games_update_creator_only ON public.pickup_games;
CREATE POLICY pickup_games_update_creator_only
  ON public.pickup_games
  FOR UPDATE
  TO authenticated
  USING (creator_user_id = (SELECT auth.uid()))
  WITH CHECK (creator_user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS pickup_games_delete_creator_only ON public.pickup_games;
CREATE POLICY pickup_games_delete_creator_only
  ON public.pickup_games
  FOR DELETE
  TO authenticated
  USING (creator_user_id = (SELECT auth.uid()));

GRANT SELECT, INSERT, UPDATE, DELETE ON public.pickup_games TO authenticated;

COMMENT ON TABLE public.pickup_games IS 'User-created pickup games (fan accounts). Phase 2: applicants, push, server purge cron.';
