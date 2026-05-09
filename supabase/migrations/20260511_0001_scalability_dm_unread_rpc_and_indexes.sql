-- Scalability pass (~50k MAU): single-query DM unread total + hot-path btree indexes.
-- Safe/idempotent: CREATE INDEX IF NOT EXISTS; CREATE OR REPLACE FUNCTION.
-- RPC mirrors client logic in DirectChatService (peer-only, read cursor, soft-delete).

-- ---------------------------------------------------------------------------
-- RPC: total unread peer DMs for auth.uid() (one round-trip vs N count queries)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_dm_unread_total()
RETURNS integer
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
  uid uuid := auth.uid();
  has_is_deleted boolean;
  n integer;
BEGIN
  IF uid IS NULL THEN
    RETURN 0;
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM information_schema.columns c
    WHERE c.table_schema = 'public'
      AND c.table_name = 'direct_messages'
      AND c.column_name = 'is_deleted'
  ) INTO has_is_deleted;

  IF has_is_deleted THEN
    SELECT COUNT(*)::integer INTO n
    FROM public.direct_messages dm
    INNER JOIN public.direct_conversations dc ON dc.id = dm.conversation_id
    LEFT JOIN public.conversation_read_state crs
      ON crs.conversation_id = dm.conversation_id
     AND crs.user_id = uid
    WHERE (dc.user_a_id = uid OR dc.user_b_id = uid)
      AND dm.sender_id <> uid
      AND dm.deleted_at IS NULL
      AND (dm.is_deleted IS NOT TRUE)
      AND dm.created_at > COALESCE(crs.last_read_at, 'epoch'::timestamptz);
  ELSE
    SELECT COUNT(*)::integer INTO n
    FROM public.direct_messages dm
    INNER JOIN public.direct_conversations dc ON dc.id = dm.conversation_id
    LEFT JOIN public.conversation_read_state crs
      ON crs.conversation_id = dm.conversation_id
     AND crs.user_id = uid
    WHERE (dc.user_a_id = uid OR dc.user_b_id = uid)
      AND dm.sender_id <> uid
      AND dm.deleted_at IS NULL
      AND dm.created_at > COALESCE(crs.last_read_at, 'epoch'::timestamptz);
  END IF;

  RETURN COALESCE(n, 0);
END;
$$;

COMMENT ON FUNCTION public.get_dm_unread_total() IS
  'Single-query unread DM total for authenticated user; replaces O(conversations) client fan-out at scale (~50k users).';

REVOKE ALL ON FUNCTION public.get_dm_unread_total() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_dm_unread_total() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_dm_unread_total() TO service_role;

-- ---------------------------------------------------------------------------
-- Indexes: Discover map / calendar / interests / chat ( btree, IF NOT EXISTS )
-- ---------------------------------------------------------------------------

-- venue_events: bounded owner/venue/date/sport filters from GameOn Discover loaders
CREATE INDEX IF NOT EXISTS idx_venue_events_owner_email_event_date
  ON public.venue_events (owner_email, event_date);

CREATE INDEX IF NOT EXISTS idx_venue_events_venue_name_event_date
  ON public.venue_events (venue_name, event_date);

CREATE INDEX IF NOT EXISTS idx_venue_events_event_date
  ON public.venue_events (event_date);

CREATE INDEX IF NOT EXISTS idx_venue_events_sport_event_date
  ON public.venue_events (sport, event_date);

-- direct_messages: per-thread history + unread counts (conversation_id + time)
CREATE INDEX IF NOT EXISTS idx_direct_messages_conversation_created
  ON public.direct_messages (conversation_id, created_at);

-- Note: direct_messages has sender_id + conversation_id; there is no recipient_id column in the app model.
CREATE INDEX IF NOT EXISTS idx_direct_messages_sender_conversation_created
  ON public.direct_messages (sender_id, conversation_id, created_at);

-- venue_event_interests: counts and upsert conflict (user_email, venue_event_id)
CREATE INDEX IF NOT EXISTS idx_venue_event_interests_venue_event_id
  ON public.venue_event_interests (venue_event_id);

CREATE INDEX IF NOT EXISTS idx_venue_event_interests_user_email_venue_event_id
  ON public.venue_event_interests (user_email, venue_event_id);

-- venue_event_comments / venue_event_vibes: per-event threads and tallies
CREATE INDEX IF NOT EXISTS idx_venue_event_comments_venue_event_created
  ON public.venue_event_comments (venue_event_id, created_at);

CREATE INDEX IF NOT EXISTS idx_venue_event_vibes_venue_event_id
  ON public.venue_event_vibes (venue_event_id);

-- games: date-range schedule pulls
CREATE INDEX IF NOT EXISTS idx_games_game_date
  ON public.games (game_date);
