-- P0: Deny direct_messages INSERT when either party has blocked the other.
-- Preserves SELECT (history), reports, conversations, and friendships.

-- ---------------------------------------------------------------------------
-- 1) blocked_users: create if missing + RLS (no-op when already provisioned)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.blocked_users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  blocker_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  blocked_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT blocked_users_no_self CHECK (blocker_user_id <> blocked_user_id),
  CONSTRAINT blocked_users_unique_pair UNIQUE (blocker_user_id, blocked_user_id)
);

CREATE INDEX IF NOT EXISTS blocked_users_blocker_idx
  ON public.blocked_users (blocker_user_id);

CREATE INDEX IF NOT EXISTS blocked_users_blocked_idx
  ON public.blocked_users (blocked_user_id);

ALTER TABLE public.blocked_users ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS blocked_users_insert_own ON public.blocked_users;
CREATE POLICY blocked_users_insert_own
  ON public.blocked_users FOR INSERT TO authenticated
  WITH CHECK (blocker_user_id = auth.uid());

DROP POLICY IF EXISTS blocked_users_select_involving_me ON public.blocked_users;
CREATE POLICY blocked_users_select_involving_me
  ON public.blocked_users FOR SELECT TO authenticated
  USING (blocker_user_id = auth.uid() OR blocked_user_id = auth.uid());

DROP POLICY IF EXISTS blocked_users_delete_own ON public.blocked_users;
CREATE POLICY blocked_users_delete_own
  ON public.blocked_users FOR DELETE TO authenticated
  USING (blocker_user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- 2) Peer auth-user resolution for business-id conversation rows
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.direct_conversation_peer_auth_user_ids(
  p_conversation_id uuid,
  p_sender_auth_user_id uuid
)
RETURNS SETOF uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH dc AS (
    SELECT user_a_id, user_b_id
    FROM public.direct_conversations
    WHERE id = p_conversation_id
  ),
  sender_business_ids AS (
    SELECT b.id
    FROM public.businesses b
    WHERE b.owner_user_id = p_sender_auth_user_id
      AND COALESCE(lower(trim(b.admin_status)), '') = 'active'
  ),
  raw_peer_ids AS (
    SELECT dc.user_a_id AS peer_id FROM dc
    UNION
    SELECT dc.user_b_id FROM dc
  ),
  resolved AS (
    SELECT DISTINCT
      CASE
        WHEN rp.peer_id = p_sender_auth_user_id THEN NULL
        WHEN rp.peer_id IN (SELECT id FROM sender_business_ids) THEN NULL
        WHEN EXISTS (
          SELECT 1
          FROM public.businesses b
          WHERE b.id = rp.peer_id
            AND b.owner_user_id IS NOT NULL
            AND COALESCE(lower(trim(b.admin_status)), '') = 'active'
        ) THEN (
          SELECT b.owner_user_id
          FROM public.businesses b
          WHERE b.id = rp.peer_id
          LIMIT 1
        )
        ELSE rp.peer_id
      END AS peer_auth_user_id
    FROM raw_peer_ids rp
  )
  SELECT peer_auth_user_id
  FROM resolved
  WHERE peer_auth_user_id IS NOT NULL
    AND peer_auth_user_id <> p_sender_auth_user_id;
$$;

COMMENT ON FUNCTION public.direct_conversation_peer_auth_user_ids(uuid, uuid) IS
  'Auth-user peer ids for DM block checks; maps businesses.id to owner_user_id.';

REVOKE ALL ON FUNCTION public.direct_conversation_peer_auth_user_ids(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.direct_conversation_peer_auth_user_ids(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.direct_conversation_peer_auth_user_ids(uuid, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 3) Server-side send permission (participant + not blocked)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.direct_message_send_allowed(
  p_conversation_id uuid,
  p_sender_auth_user_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    p_conversation_id IS NOT NULL
    AND p_sender_auth_user_id IS NOT NULL
    AND public.is_direct_conversation_participant(p_conversation_id, p_sender_auth_user_id)
    AND NOT EXISTS (
      SELECT 1
      FROM public.direct_conversation_peer_auth_user_ids(
        p_conversation_id,
        p_sender_auth_user_id
      ) AS peer(peer_auth_user_id)
      WHERE NOT public.pickup_invite_users_are_unblocked(
        p_sender_auth_user_id,
        peer.peer_auth_user_id
      )
    );
$$;

COMMENT ON FUNCTION public.direct_message_send_allowed(uuid, uuid) IS
  'True when sender is a participant and no peer auth user is in a block relationship with sender.';

REVOKE ALL ON FUNCTION public.direct_message_send_allowed(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.direct_message_send_allowed(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.direct_message_send_allowed(uuid, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 4) direct_messages INSERT policy
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS "direct_messages_insert_as_participant_sender" ON public.direct_messages;

CREATE POLICY "direct_messages_insert_as_participant_sender"
ON public.direct_messages
FOR INSERT
TO authenticated
WITH CHECK (
  sender_id = auth.uid()
  AND public.is_direct_conversation_participant(conversation_id, sender_id)
  AND public.direct_message_send_allowed(conversation_id, sender_id)
);

-- ---------------------------------------------------------------------------
-- 5) start_direct_conversation: block check before friendship gate
--    Full body from 20260808_0040 with one added guard.
-- ---------------------------------------------------------------------------
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

  IF NOT public.pickup_invite_users_are_unblocked(me, peer_user_id) THEN
    RAISE EXCEPTION 'You cannot message this user.';
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
  'Starts or returns a 1:1 DM conversation. Business friendships resolve businesses.id to owner auth ids for RLS/realtime. Blocked users cannot start new conversations.';

REVOKE ALL ON FUNCTION public.start_direct_conversation(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.start_direct_conversation(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.start_direct_conversation(uuid) TO service_role;
