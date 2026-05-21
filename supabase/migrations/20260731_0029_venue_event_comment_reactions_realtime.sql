-- Fan Chat thumbs up/down reactions need realtime so open sheets can refresh
-- affected comment summaries without restoring heavy comment polling.

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_publication_tables pt
    WHERE pt.pubname = 'supabase_realtime'
      AND pt.schemaname = 'public'
      AND pt.tablename = 'venue_event_comment_reactions'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.venue_event_comment_reactions;
  END IF;
END $$;

-- DELETE realtime payloads need comment_id so clients can refresh the affected
-- visible comment after a user removes their reaction.
ALTER TABLE public.venue_event_comment_reactions REPLICA IDENTITY FULL;

DO $$
DECLARE
  has_realtime_publication boolean;
  has_full_replica_identity boolean;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM pg_publication_tables pt
    WHERE pt.pubname = 'supabase_realtime'
      AND pt.schemaname = 'public'
      AND pt.tablename = 'venue_event_comment_reactions'
  )
  INTO has_realtime_publication;

  SELECT c.relreplident = 'f'
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relname = 'venue_event_comment_reactions'
  INTO has_full_replica_identity;

  IF NOT COALESCE(has_realtime_publication, false)
     OR NOT COALESCE(has_full_replica_identity, false) THEN
    RAISE NOTICE '[FanChatReactionDebug] realtimeSqlMissing=true publication=% replicaIdentityFull=%',
      COALESCE(has_realtime_publication, false),
      COALESCE(has_full_replica_identity, false);
  ELSE
    RAISE NOTICE '[FanChatReactionDebug] realtimeSqlMissing=false publication=true replicaIdentityFull=true';
  END IF;
END $$;
