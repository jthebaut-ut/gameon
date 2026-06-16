-- Repair business-entity DM visibility without changing the direct_messages shape.
-- Friendships may target public.businesses.id, while direct_messages/realtime are
-- authorized through the signed-in owner auth user. These functions bridge that
-- identity split and keep new conversations auth-user based.

CREATE OR REPLACE FUNCTION public.is_direct_conversation_participant(
  p_conversation_id uuid,
  p_user_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.direct_conversations dc
    WHERE dc.id = p_conversation_id
      AND p_user_id IS NOT NULL
      AND (
        dc.user_a_id = p_user_id
        OR dc.user_b_id = p_user_id
        OR EXISTS (
          SELECT 1
          FROM public.businesses b
          WHERE COALESCE(lower(trim(b.admin_status)), '') = 'active'
            AND b.owner_user_id = p_user_id
            AND (b.id = dc.user_a_id OR b.id = dc.user_b_id)
        )
      )
  );
$$;

COMMENT ON FUNCTION public.is_direct_conversation_participant(uuid, uuid) IS
  'DM participant helper: auth users participate directly, and business owners participate in legacy conversations that stored businesses.id.';

CREATE OR REPLACE FUNCTION public.is_direct_conversation_other_participant(
  p_conversation_id uuid,
  p_reporter_user_id uuid,
  p_reported_user_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.direct_conversations dc
    WHERE dc.id = p_conversation_id
      AND p_reporter_user_id IS NOT NULL
      AND p_reported_user_id IS NOT NULL
      AND public.is_direct_conversation_participant(p_conversation_id, p_reporter_user_id)
      AND (
        (
          (dc.user_a_id = p_reporter_user_id OR dc.user_b_id = p_reporter_user_id)
          AND (dc.user_a_id = p_reported_user_id OR dc.user_b_id = p_reported_user_id)
        )
        OR EXISTS (
          SELECT 1
          FROM public.businesses b
          WHERE COALESCE(lower(trim(b.admin_status)), '') = 'active'
            AND b.owner_user_id = p_reported_user_id
            AND (b.id = dc.user_a_id OR b.id = dc.user_b_id)
        )
        OR EXISTS (
          SELECT 1
          FROM public.businesses b
          WHERE COALESCE(lower(trim(b.admin_status)), '') = 'active'
            AND b.owner_user_id = p_reporter_user_id
            AND (b.id = dc.user_a_id OR b.id = dc.user_b_id)
            AND (dc.user_a_id = p_reported_user_id OR dc.user_b_id = p_reported_user_id)
        )
      )
  );
$$;

COMMENT ON FUNCTION public.is_direct_conversation_other_participant(uuid, uuid, uuid) IS
  'DM report helper with business-owner support for conversations that stored businesses.id.';

CREATE OR REPLACE FUNCTION public.can_report_direct_message(
  p_message_id uuid,
  p_reporter_user_id uuid,
  p_reported_user_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.direct_messages dm
    WHERE dm.id = p_message_id
      AND p_reporter_user_id IS NOT NULL
      AND p_reported_user_id IS NOT NULL
      AND dm.sender_id = p_reported_user_id
      AND public.is_direct_conversation_participant(dm.conversation_id, p_reporter_user_id)
  );
$$;

COMMENT ON FUNCTION public.can_report_direct_message(uuid, uuid, uuid) IS
  'Validates private message reports while allowing business owners to read legacy business-id conversations.';

DROP POLICY IF EXISTS "direct_conversations_select_participants" ON public.direct_conversations;
CREATE POLICY "direct_conversations_select_participants"
ON public.direct_conversations
FOR SELECT
TO authenticated
USING (public.is_direct_conversation_participant(id, auth.uid()));

DROP POLICY IF EXISTS "direct_messages_select_thread_participants" ON public.direct_messages;
CREATE POLICY "direct_messages_select_thread_participants"
ON public.direct_messages
FOR SELECT
TO authenticated
USING (
  public.is_direct_conversation_participant(conversation_id, auth.uid())
);

DROP POLICY IF EXISTS "direct_messages_insert_as_participant_sender" ON public.direct_messages;
CREATE POLICY "direct_messages_insert_as_participant_sender"
ON public.direct_messages
FOR INSERT
TO authenticated
WITH CHECK (
  sender_id = auth.uid()
  AND public.is_direct_conversation_participant(conversation_id, sender_id)
);

CREATE OR REPLACE FUNCTION public.start_direct_conversation(p_friend_user_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  peer_user_id uuid := p_friend_user_id;
  peer_business_owner_user_id uuid;
  peer_business_id uuid;
  peer_business_ids uuid[] := '{}'::uuid[];
  owned_business_ids uuid[] := '{}'::uuid[];
  cid uuid;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  IF p_friend_user_id IS NULL THEN
    RAISE EXCEPTION 'Friend user id is required.';
  END IF;

  SELECT b.id, b.owner_user_id
    INTO peer_business_id, peer_business_owner_user_id
  FROM public.businesses b
  WHERE b.id = p_friend_user_id
    AND COALESCE(lower(trim(b.admin_status)), '') = 'active'
    AND b.owner_user_id IS NOT NULL
  LIMIT 1;

  IF peer_business_owner_user_id IS NOT NULL THEN
    peer_user_id := peer_business_owner_user_id;
  END IF;

  SELECT COALESCE(array_agg(b.id), '{}'::uuid[])
    INTO owned_business_ids
  FROM public.businesses b
  WHERE b.owner_user_id = me
    AND COALESCE(lower(trim(b.admin_status)), '') = 'active';

  SELECT COALESCE(array_agg(b.id), '{}'::uuid[])
    INTO peer_business_ids
  FROM public.businesses b
  WHERE b.owner_user_id = peer_user_id
    AND COALESCE(lower(trim(b.admin_status)), '') = 'active';

  IF peer_user_id IS NULL OR peer_user_id = me THEN
    RAISE EXCEPTION 'You cannot message yourself.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.friendships f
    WHERE f.status = 'accepted'
      AND (
        -- Regular user <-> user friendship.
        (
          COALESCE(f.requester_entity_type, 'user') = 'user'
          AND COALESCE(f.addressee_entity_type, 'user') = 'user'
          AND (
            (f.requester_id = me AND f.addressee_id = peer_user_id)
            OR (f.requester_id = peer_user_id AND f.addressee_id = me)
          )
        )
        OR
        -- Signed-in user messaging a business; p_friend_user_id may be the business id
        -- or the owner's auth id from the repaired inbox RPC.
        (
          COALESCE(f.requester_entity_type, 'user') = 'user'
          AND COALESCE(f.addressee_entity_type, 'user') = 'business'
          AND f.requester_id = me
          AND f.addressee_id = ANY(peer_business_ids)
        )
        OR
        (
          COALESCE(f.requester_entity_type, 'user') = 'business'
          AND COALESCE(f.addressee_entity_type, 'user') = 'user'
          AND f.requester_id = ANY(peer_business_ids)
          AND f.addressee_id = me
        )
        OR
        -- Business owner messaging an accepted fan from a business-owned friendship.
        (
          COALESCE(f.requester_entity_type, 'user') = 'business'
          AND COALESCE(f.addressee_entity_type, 'user') = 'user'
          AND f.requester_id = ANY(owned_business_ids)
          AND f.addressee_id = peer_user_id
        )
        OR
        (
          COALESCE(f.requester_entity_type, 'user') = 'user'
          AND COALESCE(f.addressee_entity_type, 'user') = 'business'
          AND f.requester_id = peer_user_id
          AND f.addressee_id = ANY(owned_business_ids)
        )
      )
  ) THEN
    RAISE EXCEPTION 'You can only message accepted friends.';
  END IF;

  SELECT dc.id INTO cid
  FROM public.direct_conversations dc
  WHERE
    (dc.user_a_id = me AND dc.user_b_id = peer_user_id)
    OR (dc.user_b_id = me AND dc.user_a_id = peer_user_id)
    OR (dc.user_a_id = me AND dc.user_b_id = ANY(peer_business_ids))
    OR (dc.user_b_id = me AND dc.user_a_id = ANY(peer_business_ids))
    OR (dc.user_a_id = peer_user_id AND dc.user_b_id = ANY(owned_business_ids))
    OR (dc.user_b_id = peer_user_id AND dc.user_a_id = ANY(owned_business_ids))
  ORDER BY
    CASE
      WHEN (dc.user_a_id = me AND dc.user_b_id = peer_user_id)
        OR (dc.user_b_id = me AND dc.user_a_id = peer_user_id)
      THEN 0
      ELSE 1
    END
  LIMIT 1;

  IF cid IS NOT NULL THEN
    RETURN cid;
  END IF;

  BEGIN
    INSERT INTO public.direct_conversations (user_a_id, user_b_id)
    VALUES (me, peer_user_id)
    RETURNING id INTO cid;
  EXCEPTION WHEN unique_violation THEN
    SELECT dc.id INTO cid
    FROM public.direct_conversations dc
    WHERE (dc.user_a_id = me AND dc.user_b_id = peer_user_id)
       OR (dc.user_b_id = me AND dc.user_a_id = peer_user_id)
    LIMIT 1;
  END;

  RETURN cid;
END;
$$;

COMMENT ON FUNCTION public.start_direct_conversation(uuid) IS
  'Starts or returns a 1:1 DM conversation. Business friendships resolve businesses.id to owner auth ids for RLS/realtime.';

REVOKE ALL ON FUNCTION public.start_direct_conversation(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.start_direct_conversation(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.start_direct_conversation(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.get_dm_unread_total()
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COUNT(*)::integer
  FROM public.direct_messages dm
  LEFT JOIN public.conversation_read_state crs
    ON crs.conversation_id = dm.conversation_id
   AND crs.user_id = auth.uid()
  WHERE auth.uid() IS NOT NULL
    AND public.is_direct_conversation_participant(dm.conversation_id, auth.uid())
    AND dm.sender_id <> auth.uid()
    AND dm.deleted_at IS NULL
    AND COALESCE(dm.is_deleted, FALSE) = FALSE
    AND dm.created_at > COALESCE(crs.last_read_at, 'epoch'::timestamptz);
$$;

COMMENT ON FUNCTION public.get_dm_unread_total() IS
  'Unread DM total using business-owner aware conversation participant checks.';

REVOKE ALL ON FUNCTION public.get_dm_unread_total() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_dm_unread_total() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_dm_unread_total() TO service_role;

CREATE OR REPLACE FUNCTION public.get_dm_inbox_summaries()
RETURNS TABLE (
  friend_user_id uuid,
  friend_display_name text,
  friend_avatar_url text,
  friend_avatar_thumbnail_url text,
  friend_email text,
  friend_is_business boolean,
  friend_business_display_name text,
  last_message_body text,
  last_message_sender_id uuid,
  last_message_created_at timestamptz,
  unread_count integer
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH me AS (
    SELECT auth.uid() AS uid
  ),
  my_businesses AS (
    SELECT b.id
    FROM public.businesses b
    CROSS JOIN me
    WHERE b.owner_user_id = me.uid
      AND COALESCE(lower(trim(b.admin_status)), '') = 'active'
  ),
  accepted_friend_candidates AS (
    SELECT
      friend_user_id,
      friend_business_id
    FROM (
      SELECT
        f.addressee_id AS friend_user_id,
        NULL::uuid AS friend_business_id
      FROM public.friendships f
      CROSS JOIN me
      WHERE f.status = 'accepted'
        AND f.requester_id = me.uid
        AND COALESCE(f.requester_entity_type, 'user') = 'user'
        AND COALESCE(f.addressee_entity_type, 'user') = 'user'

      UNION ALL

      SELECT
        f.requester_id AS friend_user_id,
        NULL::uuid AS friend_business_id
      FROM public.friendships f
      CROSS JOIN me
      WHERE f.status = 'accepted'
        AND f.addressee_id = me.uid
        AND COALESCE(f.requester_entity_type, 'user') = 'user'
        AND COALESCE(f.addressee_entity_type, 'user') = 'user'

      UNION ALL

      SELECT
        b.owner_user_id AS friend_user_id,
        b.id AS friend_business_id
      FROM public.friendships f
      CROSS JOIN me
      INNER JOIN public.businesses b
        ON b.id = f.addressee_id
       AND b.owner_user_id IS NOT NULL
       AND COALESCE(lower(trim(b.admin_status)), '') = 'active'
      WHERE f.status = 'accepted'
        AND f.requester_id = me.uid
        AND COALESCE(f.requester_entity_type, 'user') = 'user'
        AND COALESCE(f.addressee_entity_type, 'user') = 'business'

      UNION ALL

      SELECT
        b.owner_user_id AS friend_user_id,
        b.id AS friend_business_id
      FROM public.friendships f
      CROSS JOIN me
      INNER JOIN public.businesses b
        ON b.id = f.requester_id
       AND b.owner_user_id IS NOT NULL
       AND COALESCE(lower(trim(b.admin_status)), '') = 'active'
      WHERE f.status = 'accepted'
        AND f.addressee_id = me.uid
        AND COALESCE(f.requester_entity_type, 'user') = 'business'
        AND COALESCE(f.addressee_entity_type, 'user') = 'user'

      UNION ALL

      SELECT
        CASE
          WHEN COALESCE(f.requester_entity_type, 'user') = 'business' THEN f.addressee_id
          ELSE f.requester_id
        END AS friend_user_id,
        NULL::uuid AS friend_business_id
      FROM public.friendships f
      INNER JOIN my_businesses mb
        ON (
          COALESCE(f.requester_entity_type, 'user') = 'business'
          AND f.requester_id = mb.id
        )
        OR (
          COALESCE(f.addressee_entity_type, 'user') = 'business'
          AND f.addressee_id = mb.id
        )
      WHERE f.status = 'accepted'
    ) x
    WHERE friend_user_id IS NOT NULL
  ),
  accepted_friends AS (
    SELECT
      friend_user_id,
      (array_agg(friend_business_id) FILTER (WHERE friend_business_id IS NOT NULL))[1] AS friend_business_id
    FROM accepted_friend_candidates
    GROUP BY friend_user_id
  ),
  base AS (
    SELECT
      af.friend_user_id,
      af.friend_business_id,
      dc.id AS conversation_id
    FROM accepted_friends af
    CROSS JOIN me
    LEFT JOIN LATERAL (
      SELECT dc_inner.id
      FROM public.direct_conversations dc_inner
      WHERE
        (dc_inner.user_a_id = me.uid AND dc_inner.user_b_id = af.friend_user_id)
        OR (dc_inner.user_b_id = me.uid AND dc_inner.user_a_id = af.friend_user_id)
        OR (
          af.friend_business_id IS NOT NULL
          AND (
            (dc_inner.user_a_id = me.uid AND dc_inner.user_b_id = af.friend_business_id)
            OR (dc_inner.user_b_id = me.uid AND dc_inner.user_a_id = af.friend_business_id)
          )
        )
        OR EXISTS (
          SELECT 1
          FROM my_businesses mb
          WHERE
            (dc_inner.user_a_id = af.friend_user_id AND dc_inner.user_b_id = mb.id)
            OR (dc_inner.user_b_id = af.friend_user_id AND dc_inner.user_a_id = mb.id)
        )
      ORDER BY
        CASE
          WHEN (dc_inner.user_a_id = me.uid AND dc_inner.user_b_id = af.friend_user_id)
            OR (dc_inner.user_b_id = me.uid AND dc_inner.user_a_id = af.friend_user_id)
          THEN 0
          ELSE 1
        END
      LIMIT 1
    ) dc ON TRUE
  )
  SELECT
    base.friend_user_id,
    CASE
      WHEN COALESCE(target_biz.friend_is_business, biz.friend_is_business, FALSE) THEN
        COALESCE(
          target_biz.friend_business_display_name,
          biz.friend_business_display_name,
          target_biz.friend_email,
          biz.friend_email,
          'Business'
        )
      ELSE
        COALESCE(
          NULLIF(trim(up.display_name), ''),
          NULLIF(split_part(COALESCE(up.email, biz.friend_email, ''), '@', 1), ''),
          'Player'
        )
    END AS friend_display_name,
    CASE
      WHEN COALESCE(target_biz.friend_is_business, biz.friend_is_business, FALSE) THEN NULL
      ELSE up.avatar_url
    END AS friend_avatar_url,
    CASE
      WHEN COALESCE(target_biz.friend_is_business, biz.friend_is_business, FALSE) THEN NULL
      ELSE up.avatar_thumbnail_url
    END AS friend_avatar_thumbnail_url,
    COALESCE(target_biz.friend_email, biz.friend_email, NULLIF(lower(trim(up.email)), '')) AS friend_email,
    COALESCE(target_biz.friend_is_business, biz.friend_is_business, FALSE) AS friend_is_business,
    COALESCE(target_biz.friend_business_display_name, biz.friend_business_display_name) AS friend_business_display_name,
    latest_dm.body AS last_message_body,
    latest_dm.sender_id AS last_message_sender_id,
    latest_dm.created_at AS last_message_created_at,
    COALESCE(unread.unread_count, 0) AS unread_count
  FROM base
  LEFT JOIN public.user_profiles up
    ON up.id = base.friend_user_id
   AND COALESCE(lower(trim(up.admin_status)), '') <> 'disabled'
  LEFT JOIN LATERAL (
    SELECT
      TRUE AS friend_is_business,
      NULLIF(trim(b.display_name), '') AS friend_business_display_name,
      NULLIF(lower(trim(b.owner_email)), '') AS friend_email
    FROM public.businesses b
    WHERE b.id = base.friend_business_id
      AND COALESCE(lower(trim(b.admin_status)), '') = 'active'
    LIMIT 1
  ) target_biz ON TRUE
  LEFT JOIN LATERAL (
    SELECT
      TRUE AS friend_is_business,
      NULLIF(trim(b.display_name), '') AS friend_business_display_name,
      NULLIF(lower(trim(b.owner_email)), '') AS friend_email
    FROM public.businesses b
    WHERE COALESCE(lower(trim(b.admin_status)), '') = 'active'
      AND base.friend_business_id IS NULL
      AND (
        b.owner_user_id = base.friend_user_id
        OR (
          NULLIF(lower(trim(b.owner_email)), '') IS NOT NULL
          AND NULLIF(lower(trim(b.owner_email)), '') = NULLIF(lower(trim(COALESCE(up.email, ''))), '')
        )
      )
    ORDER BY
      CASE WHEN b.owner_user_id = base.friend_user_id THEN 0 ELSE 1 END,
      CASE WHEN NULLIF(trim(b.display_name), '') IS NOT NULL THEN 0 ELSE 1 END,
      b.created_at DESC NULLS LAST
    LIMIT 1
  ) biz ON TRUE
  LEFT JOIN LATERAL (
    SELECT dm.body, dm.sender_id, dm.created_at
    FROM public.direct_messages dm
    WHERE dm.conversation_id = base.conversation_id
      AND dm.deleted_at IS NULL
      AND COALESCE(dm.is_deleted, FALSE) = FALSE
    ORDER BY dm.created_at DESC, dm.id DESC
    LIMIT 1
  ) latest_dm ON TRUE
  LEFT JOIN public.conversation_read_state crs
    ON crs.conversation_id = base.conversation_id
   AND crs.user_id = (SELECT uid FROM me)
  LEFT JOIN LATERAL (
    SELECT COUNT(*)::integer AS unread_count
    FROM public.direct_messages dm
    WHERE dm.conversation_id = base.conversation_id
      AND dm.sender_id <> (SELECT uid FROM me)
      AND dm.deleted_at IS NULL
      AND COALESCE(dm.is_deleted, FALSE) = FALSE
      AND dm.created_at > COALESCE(crs.last_read_at, 'epoch'::timestamptz)
  ) unread ON base.conversation_id IS NOT NULL
  WHERE (SELECT uid FROM me) IS NOT NULL
  ORDER BY latest_dm.created_at DESC NULLS LAST, base.friend_user_id;
$$;

COMMENT ON FUNCTION public.get_dm_inbox_summaries() IS
  'Accepted-friend DM inbox summaries with business friendships mapped to owner auth ids for realtime/RLS.';

REVOKE ALL ON FUNCTION public.get_dm_inbox_summaries() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_dm_inbox_summaries() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_dm_inbox_summaries() TO service_role;
