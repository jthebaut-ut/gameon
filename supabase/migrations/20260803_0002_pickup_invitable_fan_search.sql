-- Pickup invite fan search: safe public fan lookup by handle/display name.

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
      AND up.admin_disabled_at IS NULL
      AND COALESCE(up.is_deleted, false) = false
      AND COALESCE(up.is_business_account, false) = false
  )
  AND NOT EXISTS (
    SELECT 1
    FROM public.user_bans ub
    WHERE ub.user_id = p_user_id
      AND public.is_user_ban_active(ub.expires_at, ub.lifted_at)
  );
$$;

CREATE OR REPLACE FUNCTION public.pickup_invite_user_is_public_invitable(p_user_id uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.pickup_invite_user_is_active(p_user_id)
    AND EXISTS (
      SELECT 1
      FROM public.user_profiles up
      WHERE up.id = p_user_id
        AND COALESCE(up.is_deleted, false) = false
        AND up.admin_disabled_at IS NULL
        AND COALESCE(up.discoverable_by_fans, true) = true
    );
$$;

CREATE OR REPLACE FUNCTION public.search_pickup_invitable_fans(
  p_query text,
  p_limit int DEFAULT 20
)
RETURNS TABLE (
  user_id uuid,
  display_name text,
  handle text,
  avatar_url text,
  is_friend boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  q text := lower(btrim(coalesce(p_query, '')));
  handle_q text;
  lim int := least(greatest(coalesce(p_limit, 20), 1), 50);
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  q := regexp_replace(q, '^@+', '');
  IF length(q) < 2 THEN
    RETURN;
  END IF;

  handle_q := public.fangeo_normalize_handle(q);

  RETURN QUERY
  WITH candidates AS (
    SELECT
      up.id,
      nullif(btrim(coalesce(up.display_name, '')), '') AS safe_display_name,
      nullif(public.fangeo_normalize_handle(coalesce(up.handle, up.username)), '') AS safe_handle,
      nullif(btrim(coalesce(up.avatar_thumbnail_url, up.avatar_url, '')), '') AS safe_avatar_url,
      EXISTS (
        SELECT 1
        FROM public.friendships f
        WHERE f.status = 'accepted'
          AND COALESCE(f.requester_entity_type, 'user') = 'user'
          AND COALESCE(f.addressee_entity_type, 'user') = 'user'
          AND (
            (f.requester_id = me AND f.addressee_id = up.id)
            OR (f.requester_id = up.id AND f.addressee_id = me)
          )
      ) AS friend_match,
      CASE
        WHEN handle_q IS NOT NULL
          AND public.fangeo_normalize_handle(coalesce(up.handle, up.username)) = handle_q THEN 0
        WHEN handle_q IS NOT NULL
          AND public.fangeo_normalize_handle(coalesce(up.handle, up.username)) LIKE handle_q || '%' THEN 1
        WHEN lower(btrim(coalesce(up.display_name, ''))) = q THEN 2
        ELSE 3
      END AS rank_order
    FROM public.user_profiles up
    WHERE up.id <> me
      AND public.pickup_invite_user_is_public_invitable(up.id)
      AND public.pickup_invite_users_are_unblocked(me, up.id)
      AND (
        (
          handle_q IS NOT NULL
          AND public.fangeo_normalize_handle(coalesce(up.handle, up.username)) LIKE handle_q || '%'
        )
        OR lower(btrim(coalesce(up.display_name, ''))) LIKE '%' || q || '%'
      )
  )
  SELECT
    c.id AS user_id,
    coalesce(c.safe_display_name, c.safe_handle, 'Fan') AS display_name,
    c.safe_handle AS handle,
    c.safe_avatar_url AS avatar_url,
    c.friend_match AS is_friend
  FROM candidates c
  ORDER BY c.rank_order ASC, lower(coalesce(c.safe_display_name, c.safe_handle, 'fan')) ASC, c.id ASC
  LIMIT lim;
END;
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
       OR NOT public.pickup_invite_users_are_unblocked(me, invitee)
       OR NOT (
         public.pickup_invite_users_are_friends(me, invitee)
         OR public.pickup_invite_user_is_public_invitable(invitee)
       ) THEN
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

REVOKE ALL ON FUNCTION public.pickup_invite_user_is_public_invitable(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pickup_invite_user_is_public_invitable(uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.pickup_invite_user_is_active(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pickup_invite_user_is_active(uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.search_pickup_invitable_fans(text, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.search_pickup_invitable_fans(text, int) TO authenticated;

REVOKE ALL ON FUNCTION public.create_pickup_game_invites(uuid, uuid[], text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_pickup_game_invites(uuid, uuid[], text) TO authenticated;

COMMENT ON FUNCTION public.search_pickup_invitable_fans(text, int) IS
  'Authenticated safe fan search for pickup invites. Returns public fields only and excludes self, blocked, banned, deleted, disabled, business, and non-discoverable profiles.';
