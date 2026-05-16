-- Post-game pickup organizer ratings (private feedback; public aggregates only via RPC).

-- ---------------------------------------------------------------------------
-- Table
-- ---------------------------------------------------------------------------
CREATE TABLE public.pickup_game_creator_ratings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pickup_game_id uuid NOT NULL REFERENCES public.pickup_games (id) ON DELETE CASCADE,
  creator_user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  rater_user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  rating integer NOT NULL CHECK (rating >= 1 AND rating <= 5),
  feedback text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz,
  CONSTRAINT pickup_game_creator_ratings_rater_not_creator CHECK (rater_user_id <> creator_user_id),
  CONSTRAINT pickup_game_creator_ratings_one_per_rater UNIQUE (pickup_game_id, rater_user_id),
  CONSTRAINT pickup_game_creator_ratings_feedback_len CHECK (
    feedback IS NULL OR char_length(feedback) <= 1000
  )
);

CREATE INDEX pickup_game_creator_ratings_creator_idx
  ON public.pickup_game_creator_ratings (creator_user_id);

CREATE INDEX pickup_game_creator_ratings_pickup_game_idx
  ON public.pickup_game_creator_ratings (pickup_game_id);

COMMENT ON TABLE public.pickup_game_creator_ratings IS
  'Fan ratings of pickup organizers after play; feedback is private (moderation), public UI uses RPC aggregates only.';

-- ---------------------------------------------------------------------------
-- creator_user_id must match pickup_games.creator_user_id (defense in depth)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.pickup_game_creator_ratings_enforce_game_creator()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  cc uuid;
BEGIN
  SELECT g.creator_user_id INTO cc
  FROM public.pickup_games g
  WHERE g.id = NEW.pickup_game_id;

  IF cc IS NULL THEN
    RAISE EXCEPTION 'pickup_game_creator_ratings_missing_game' USING ERRCODE = '23503';
  END IF;

  IF NEW.creator_user_id IS DISTINCT FROM cc THEN
    RAISE EXCEPTION 'pickup_game_creator_ratings_creator_mismatch' USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS pickup_game_creator_ratings_enforce_game_creator_bi
  ON public.pickup_game_creator_ratings;
CREATE TRIGGER pickup_game_creator_ratings_enforce_game_creator_bi
  BEFORE INSERT OR UPDATE OF pickup_game_id, creator_user_id
  ON public.pickup_game_creator_ratings
  FOR EACH ROW
  EXECUTE FUNCTION public.pickup_game_creator_ratings_enforce_game_creator();

-- ---------------------------------------------------------------------------
-- updated_at on change
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.pickup_game_creator_ratings_touch_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'UPDATE' THEN
    NEW.updated_at := now();
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS pickup_game_creator_ratings_touch_updated_at_bu
  ON public.pickup_game_creator_ratings;
CREATE TRIGGER pickup_game_creator_ratings_touch_updated_at_bu
  BEFORE UPDATE ON public.pickup_game_creator_ratings
  FOR EACH ROW
  EXECUTE FUNCTION public.pickup_game_creator_ratings_touch_updated_at();

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
ALTER TABLE public.pickup_game_creator_ratings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS pickup_game_creator_ratings_select_own ON public.pickup_game_creator_ratings;
CREATE POLICY pickup_game_creator_ratings_select_own
  ON public.pickup_game_creator_ratings
  FOR SELECT
  TO authenticated
  USING (rater_user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS pickup_game_creator_ratings_insert_eligible ON public.pickup_game_creator_ratings;
CREATE POLICY pickup_game_creator_ratings_insert_eligible
  ON public.pickup_game_creator_ratings
  FOR INSERT
  TO authenticated
  WITH CHECK (
    rater_user_id = (SELECT auth.uid())
    AND EXISTS (
      SELECT 1
      FROM public.pickup_games g
      WHERE g.id = pickup_game_id
        AND g.creator_user_id = creator_user_id
        AND (
          g.game_start_at <= now()
          OR (g.remove_after_at IS NOT NULL AND g.remove_after_at <= now())
        )
    )
    AND EXISTS (
      SELECT 1
      FROM public.pickup_game_requests r
      WHERE r.pickup_game_id = pickup_game_id
        AND r.requester_user_id = (SELECT auth.uid())
        AND lower(trim(both from r.status)) = 'approved'
    )
  );

DROP POLICY IF EXISTS pickup_game_creator_ratings_update_own ON public.pickup_game_creator_ratings;
CREATE POLICY pickup_game_creator_ratings_update_own
  ON public.pickup_game_creator_ratings
  FOR UPDATE
  TO authenticated
  USING (rater_user_id = (SELECT auth.uid()))
  WITH CHECK (rater_user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS pickup_game_creator_ratings_delete_own ON public.pickup_game_creator_ratings;
CREATE POLICY pickup_game_creator_ratings_delete_own
  ON public.pickup_game_creator_ratings
  FOR DELETE
  TO authenticated
  USING (rater_user_id = (SELECT auth.uid()));

GRANT SELECT, INSERT, UPDATE, DELETE ON public.pickup_game_creator_ratings TO authenticated;

-- ---------------------------------------------------------------------------
-- Public aggregates (no feedback); SECURITY DEFINER — not gated on RLS table reads
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.pickup_creator_public_rating_stats(p_creator_user_id uuid)
RETURNS TABLE (avg_rating numeric, rating_count bigint)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    CASE
      WHEN count(*) = 0 THEN NULL::numeric
      ELSE round(avg(rating)::numeric, 2)
    END,
    count(*)::bigint
  FROM public.pickup_game_creator_ratings
  WHERE creator_user_id = p_creator_user_id;
$$;

REVOKE ALL ON FUNCTION public.pickup_creator_public_rating_stats(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pickup_creator_public_rating_stats(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.pickup_creator_public_rating_stats(uuid) TO authenticated;

COMMENT ON FUNCTION public.pickup_creator_public_rating_stats(uuid) IS
  'Returns organizer average star rating and count across all pickup games; feedback text never exposed here.';
