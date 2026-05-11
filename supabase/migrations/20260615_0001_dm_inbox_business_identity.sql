-- Enrich DM inbox summaries with explicit business identity fields for chat row rendering.

DROP FUNCTION IF EXISTS public.get_dm_inbox_summaries();

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
  accepted_friends AS (
    SELECT DISTINCT
      CASE
        WHEN f.requester_id = me.uid THEN f.addressee_id
        ELSE f.requester_id
      END AS friend_user_id
    FROM public.friendships f
    CROSS JOIN me
    WHERE me.uid IS NOT NULL
      AND f.status = 'accepted'
      AND (f.requester_id = me.uid OR f.addressee_id = me.uid)
  ),
  base AS (
    SELECT
      af.friend_user_id,
      dc.id AS conversation_id
    FROM accepted_friends af
    CROSS JOIN me
    LEFT JOIN public.direct_conversations dc
      ON (dc.user_a_id = me.uid AND dc.user_b_id = af.friend_user_id)
      OR (dc.user_b_id = me.uid AND dc.user_a_id = af.friend_user_id)
  )
  SELECT
    base.friend_user_id,
    CASE
      WHEN COALESCE(biz.friend_is_business, FALSE) THEN
        COALESCE(
          biz.friend_business_display_name,
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
      WHEN COALESCE(biz.friend_is_business, FALSE) THEN NULL
      ELSE up.avatar_url
    END AS friend_avatar_url,
    CASE
      WHEN COALESCE(biz.friend_is_business, FALSE) THEN NULL
      ELSE up.avatar_thumbnail_url
    END AS friend_avatar_thumbnail_url,
    COALESCE(biz.friend_email, NULLIF(lower(trim(up.email)), '')) AS friend_email,
    COALESCE(biz.friend_is_business, FALSE) AS friend_is_business,
    biz.friend_business_display_name,
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
    WHERE COALESCE(lower(trim(b.admin_status)), '') = 'active'
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
  'Accepted-friend DM inbox summaries enriched with explicit business identity fields for chat list and DM header rendering.';

REVOKE ALL ON FUNCTION public.get_dm_inbox_summaries() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_dm_inbox_summaries() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_dm_inbox_summaries() TO service_role;
