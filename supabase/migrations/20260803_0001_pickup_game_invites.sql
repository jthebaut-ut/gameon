-- Pickup game friend invites: host-created invites for accepted FanGeo friends.

CREATE TABLE IF NOT EXISTS public.pickup_game_invites (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pickup_game_id uuid NOT NULL REFERENCES public.pickup_games(id) ON DELETE CASCADE,
  inviter_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  invitee_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'accepted', 'maybe', 'declined', 'cancelled')),
  message text,
  created_at timestamptz NOT NULL DEFAULT now(),
  responded_at timestamptz,
  UNIQUE (pickup_game_id, invitee_user_id),
  CHECK (inviter_user_id <> invitee_user_id)
);

CREATE INDEX IF NOT EXISTS pickup_game_invites_game_id_idx
  ON public.pickup_game_invites (pickup_game_id);

CREATE INDEX IF NOT EXISTS pickup_game_invites_inviter_idx
  ON public.pickup_game_invites (inviter_user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS pickup_game_invites_invitee_pending_idx
  ON public.pickup_game_invites (invitee_user_id, created_at DESC)
  WHERE status IN ('pending', 'maybe');

ALTER TABLE public.pickup_game_invites ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.pickup_game_invites_touch_response()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'UPDATE'
     AND NEW.status IS DISTINCT FROM OLD.status
     AND NEW.status IN ('accepted', 'maybe', 'declined', 'cancelled')
     AND NEW.responded_at IS NULL THEN
    NEW.responded_at := now();
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS pickup_game_invites_touch_response_bu ON public.pickup_game_invites;
CREATE TRIGGER pickup_game_invites_touch_response_bu
  BEFORE UPDATE ON public.pickup_game_invites
  FOR EACH ROW
  EXECUTE FUNCTION public.pickup_game_invites_touch_response();

CREATE OR REPLACE FUNCTION public.pickup_invite_users_are_friends(
  p_user_a uuid,
  p_user_b uuid
)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.friendships f
    WHERE f.status = 'accepted'
      AND COALESCE(f.requester_entity_type, 'user') = 'user'
      AND COALESCE(f.addressee_entity_type, 'user') = 'user'
      AND (
        (f.requester_id = p_user_a AND f.addressee_id = p_user_b)
        OR (f.requester_id = p_user_b AND f.addressee_id = p_user_a)
      )
  );
$$;

CREATE OR REPLACE FUNCTION public.pickup_invite_users_are_unblocked(
  p_user_a uuid,
  p_user_b uuid
)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT NOT EXISTS (
    SELECT 1
    FROM public.blocked_users b
    WHERE (b.blocker_user_id = p_user_a AND b.blocked_user_id = p_user_b)
       OR (b.blocker_user_id = p_user_b AND b.blocked_user_id = p_user_a)
  );
$$;

CREATE OR REPLACE FUNCTION public.pickup_invite_user_is_active(p_user_id uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.user_profiles up
    WHERE up.id = p_user_id
      AND COALESCE(lower(trim(up.admin_status)), 'active') = 'active'
      AND COALESCE(up.is_business_account, false) = false
  )
  AND NOT EXISTS (
    SELECT 1
    FROM public.user_bans ub
    WHERE ub.user_id = p_user_id
      AND public.is_user_ban_active(ub.expires_at, ub.lifted_at)
  );
$$;

CREATE OR REPLACE FUNCTION public.create_pickup_game_invites(
  p_pickup_game_id uuid,
  p_invitee_user_ids uuid[],
  p_message text DEFAULT NULL
)
RETURNS TABLE (
  invitee_user_id uuid,
  invite_id uuid,
  outcome text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  clean_message text := nullif(btrim(coalesce(p_message, '')), '');
  invitee uuid;
  existing_id uuid;
  inserted_id uuid;
  active_invite_count int;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  IF NOT public.pickup_invite_user_is_active(me) THEN
    RAISE EXCEPTION 'pickup_inviter_not_allowed';
  END IF;

  IF p_pickup_game_id IS NULL THEN
    RAISE EXCEPTION 'pickup_game_required';
  END IF;

  IF p_invitee_user_ids IS NULL OR array_length(p_invitee_user_ids, 1) IS NULL THEN
    RETURN;
  END IF;

  PERFORM 1
  FROM public.pickup_games g
  WHERE g.id = p_pickup_game_id
    AND g.creator_user_id = me
    AND g.status = 'active'
    AND (g.remove_after_at IS NULL OR g.remove_after_at > now())
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'pickup_game_not_invitable';
  END IF;

  SELECT count(*)::int
  INTO active_invite_count
  FROM public.pickup_game_invites i
  WHERE i.pickup_game_id = p_pickup_game_id
    AND i.status <> 'cancelled';

  FOR invitee IN
    SELECT DISTINCT x
    FROM unnest(p_invitee_user_ids) AS x
    WHERE x IS NOT NULL
    LIMIT 20
  LOOP
    existing_id := NULL;
    inserted_id := NULL;

    SELECT i.id INTO existing_id
    FROM public.pickup_game_invites i
    WHERE i.pickup_game_id = p_pickup_game_id
      AND i.invitee_user_id = invitee
    LIMIT 1;

    IF existing_id IS NOT NULL THEN
      invitee_user_id := invitee;
      invite_id := existing_id;
      outcome := 'duplicate';
      RETURN NEXT;
    ELSIF active_invite_count >= 20 THEN
      invitee_user_id := invitee;
      invite_id := NULL;
      outcome := 'max_reached';
      RETURN NEXT;
    ELSIF invitee = me
       OR NOT public.pickup_invite_user_is_active(invitee)
       OR NOT public.pickup_invite_users_are_friends(me, invitee)
       OR NOT public.pickup_invite_users_are_unblocked(me, invitee) THEN
      invitee_user_id := invitee;
      invite_id := NULL;
      outcome := 'skipped';
      RETURN NEXT;
    ELSE
      INSERT INTO public.pickup_game_invites (
        pickup_game_id,
        inviter_user_id,
        invitee_user_id,
        message
      )
      VALUES (
        p_pickup_game_id,
        me,
        invitee,
        CASE WHEN clean_message IS NULL THEN NULL ELSE left(clean_message, 280) END
      )
      RETURNING id INTO inserted_id;

      active_invite_count := active_invite_count + 1;
      invitee_user_id := invitee;
      invite_id := inserted_id;
      outcome := 'created';
      RETURN NEXT;
    END IF;
  END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION public.respond_to_pickup_game_invite(
  p_invite_id uuid,
  p_status text
)
RETURNS public.pickup_game_invites
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  normalized_status text := lower(btrim(coalesce(p_status, '')));
  inv public.pickup_game_invites%ROWTYPE;
  game_row public.pickup_games%ROWTYPE;
  display_name text;
  existing_approved_id uuid;
  request_message text;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  IF normalized_status NOT IN ('accepted', 'maybe', 'declined') THEN
    RAISE EXCEPTION 'pickup_invite_status_forbidden';
  END IF;

  IF NOT public.pickup_invite_user_is_active(me) THEN
    RAISE EXCEPTION 'pickup_invitee_not_allowed';
  END IF;

  SELECT *
  INTO inv
  FROM public.pickup_game_invites
  WHERE id = p_invite_id
    AND invitee_user_id = me
    AND status IN ('pending', 'maybe')
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'pickup_invite_not_found';
  END IF;

  SELECT *
  INTO game_row
  FROM public.pickup_games
  WHERE id = inv.pickup_game_id
  FOR UPDATE;

  IF NOT FOUND
     OR game_row.status <> 'active'
     OR (game_row.remove_after_at IS NOT NULL AND game_row.remove_after_at <= now()) THEN
    RAISE EXCEPTION 'pickup_game_not_invitable';
  END IF;

  IF normalized_status = 'accepted' THEN
    SELECT r.id
    INTO existing_approved_id
    FROM public.pickup_game_requests r
    WHERE r.pickup_game_id = inv.pickup_game_id
      AND r.requester_user_id = me
      AND r.status = 'approved'
    LIMIT 1;

    IF existing_approved_id IS NULL THEN
      IF game_row.approved_join_count >= game_row.players_needed THEN
        RAISE EXCEPTION 'pickup_game_full';
      END IF;

      UPDATE public.pickup_game_requests r
      SET status = 'cancelled'
      WHERE r.pickup_game_id = inv.pickup_game_id
        AND r.requester_user_id = me
        AND r.status = 'pending';

      SELECT nullif(btrim(coalesce(up.display_name, up.username, '')), '')
      INTO display_name
      FROM public.user_profiles up
      WHERE up.id = me
      LIMIT 1;

      request_message := 'Accepted invite';
      IF inv.message IS NOT NULL AND btrim(inv.message) <> '' THEN
        request_message := left('Accepted invite: ' || btrim(inv.message), 280);
      END IF;

      INSERT INTO public.pickup_game_requests (
        pickup_game_id,
        requester_user_id,
        requester_email,
        requester_display_name,
        requester_skill_level,
        message,
        status,
        responded_at
      )
      VALUES (
        inv.pickup_game_id,
        me,
        NULL,
        display_name,
        'casual',
        request_message,
        'approved',
        now()
      );
    END IF;
  END IF;

  UPDATE public.pickup_game_invites
  SET
    status = normalized_status,
    responded_at = now()
  WHERE id = inv.id
  RETURNING * INTO inv;

  RETURN inv;
END;
$$;

DROP POLICY IF EXISTS pickup_game_invites_select_own ON public.pickup_game_invites;
CREATE POLICY pickup_game_invites_select_own
  ON public.pickup_game_invites
  FOR SELECT
  TO authenticated
  USING (
    inviter_user_id = auth.uid()
    OR invitee_user_id = auth.uid()
  );

DROP POLICY IF EXISTS pickup_game_invites_insert_host_to_friend ON public.pickup_game_invites;
CREATE POLICY pickup_game_invites_insert_host_to_friend
  ON public.pickup_game_invites
  FOR INSERT
  TO authenticated
  WITH CHECK (
    inviter_user_id = auth.uid()
    AND public.pickup_invite_user_is_active(auth.uid())
    AND public.pickup_invite_user_is_active(invitee_user_id)
    AND public.pickup_invite_users_are_friends(inviter_user_id, invitee_user_id)
    AND public.pickup_invite_users_are_unblocked(inviter_user_id, invitee_user_id)
    AND EXISTS (
      SELECT 1
      FROM public.pickup_games g
      WHERE g.id = pickup_game_id
        AND g.creator_user_id = auth.uid()
        AND g.status = 'active'
        AND (g.remove_after_at IS NULL OR g.remove_after_at > now())
    )
  );

DROP POLICY IF EXISTS pickup_game_invites_update_inviter_cancel ON public.pickup_game_invites;
CREATE POLICY pickup_game_invites_update_inviter_cancel
  ON public.pickup_game_invites
  FOR UPDATE
  TO authenticated
  USING (inviter_user_id = auth.uid())
  WITH CHECK (
    inviter_user_id = auth.uid()
    AND status = 'cancelled'
  );

DROP POLICY IF EXISTS pickup_game_invites_update_invitee_respond ON public.pickup_game_invites;
CREATE POLICY pickup_game_invites_update_invitee_respond
  ON public.pickup_game_invites
  FOR UPDATE
  TO authenticated
  USING (invitee_user_id = auth.uid())
  WITH CHECK (
    invitee_user_id = auth.uid()
    AND status IN ('accepted', 'maybe', 'declined')
  );

REVOKE ALL ON public.pickup_game_invites FROM anon;
GRANT SELECT, INSERT, UPDATE ON public.pickup_game_invites TO authenticated;

REVOKE ALL ON FUNCTION public.create_pickup_game_invites(uuid, uuid[], text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_pickup_game_invites(uuid, uuid[], text) TO authenticated;

REVOKE ALL ON FUNCTION public.respond_to_pickup_game_invite(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.respond_to_pickup_game_invite(uuid, text) TO authenticated;

REVOKE ALL ON FUNCTION public.pickup_invite_users_are_friends(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pickup_invite_users_are_friends(uuid, uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.pickup_invite_users_are_unblocked(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pickup_invite_users_are_unblocked(uuid, uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.pickup_invite_user_is_active(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pickup_invite_user_is_active(uuid) TO authenticated;

COMMENT ON TABLE public.pickup_game_invites IS
  'Friend-to-friend invitations for host-created pickup, practice, and scrimmage games.';
