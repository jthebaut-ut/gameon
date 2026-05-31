-- Privacy-safe aggregate demand signal for Business Suggested Games.
-- Returns only counts by live_match_id; never exposes user_ids or saved rows.

CREATE INDEX IF NOT EXISTS idx_saved_pro_games_live_match_id
  ON public.saved_pro_games (live_match_id);

CREATE OR REPLACE FUNCTION public.get_saved_pro_game_counts(p_live_match_ids text[])
RETURNS TABLE (
  live_match_id text,
  saved_count integer
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
  SELECT
    saved_pro_games.live_match_id,
    COUNT(*)::integer AS saved_count
  FROM public.saved_pro_games
  WHERE saved_pro_games.live_match_id = ANY(COALESCE(p_live_match_ids, ARRAY[]::text[]))
  GROUP BY saved_pro_games.live_match_id;
$$;

REVOKE ALL ON FUNCTION public.get_saved_pro_game_counts(text[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_saved_pro_game_counts(text[]) TO authenticated;
