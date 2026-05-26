-- Keep full pickup games visible while preserving requester-scoped private reads.
-- Full games should render as Full, not disappear from Discover or Playing.

CREATE OR REPLACE FUNCTION public.can_read_pickup_game_for_requester(p_pickup_game_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.pickup_game_requests r
    WHERE r.pickup_game_id = p_pickup_game_id
      AND r.requester_user_id = auth.uid()
      AND r.status IN ('pending', 'approved', 'rejected')
  );
$$;

REVOKE ALL ON FUNCTION public.can_read_pickup_game_for_requester(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.can_read_pickup_game_for_requester(uuid) TO authenticated;

DROP POLICY IF EXISTS pickup_games_select_authenticated ON public.pickup_games;
CREATE POLICY pickup_games_select_authenticated
  ON public.pickup_games
  FOR SELECT
  TO authenticated
  USING (
    creator_user_id = auth.uid()
    OR (
      status = 'active'
      AND is_visible
      AND (remove_after_at IS NULL OR remove_after_at > now())
    )
    OR public.can_read_pickup_game_for_requester(id)
  );

GRANT SELECT ON public.pickup_games TO authenticated;
