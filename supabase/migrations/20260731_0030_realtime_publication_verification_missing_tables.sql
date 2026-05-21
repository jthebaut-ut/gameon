-- Verification-first Supabase Realtime publication coverage for existing iOS listeners.
--
-- Safety constraints:
-- - Publication membership only; no RLS policies are changed.
-- - No table schemas, indexes, triggers, replica identity settings, or app behavior are changed.
-- - Each table is added only when it exists and is not already in `supabase_realtime`.
-- - NOTICE output and the final SELECT are intended for manual verification in Supabase SQL Editor.

DO $$
DECLARE
  target_table text;
  target_reason text;
  table_exists boolean;
  already_published boolean;
BEGIN
  FOR target_table, target_reason IN
    SELECT *
    FROM (VALUES
      (
        'conversation_read_state',
        'DM unread badge/read cursor listener in iOS subscribes to read-state changes so badges can update after mark-read writes.'
      ),
      (
        'venue_event_vibes',
        'Fan Chat crowd reaction/vibe listeners subscribe to vibe changes for Discover previews and venue owner analytics.'
      ),
      (
        'venue_event_interests',
        'Venue owner analytics subscribes to Going/interest changes for owned event engagement refreshes.'
      ),
      (
        'venue_event_predictions',
        'Venue prediction modules subscribe to prediction row changes before debounced aggregate summary refresh.'
      ),
      (
        'pickup_games',
        'Following pickup activity subscribes to pickup game row updates for requester game cards.'
      )
    ) AS missing_realtime_tables(tablename, reason)
  LOOP
    SELECT to_regclass(format('public.%I', target_table)) IS NOT NULL
    INTO table_exists;

    IF NOT table_exists THEN
      RAISE NOTICE '[RealtimePublicationVerify] table=public.% status=skipped_missing_table reason=%',
        target_table,
        target_reason;
      CONTINUE;
    END IF;

    SELECT EXISTS (
      SELECT 1
      FROM pg_publication_tables pt
      WHERE pt.pubname = 'supabase_realtime'
        AND pt.schemaname = 'public'
        AND pt.tablename = target_table
    )
    INTO already_published;

    IF already_published THEN
      RAISE NOTICE '[RealtimePublicationVerify] table=public.% status=already_published reason=%',
        target_table,
        target_reason;
    ELSE
      EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE public.%I', target_table);
      RAISE NOTICE '[RealtimePublicationVerify] table=public.% status=added_to_supabase_realtime reason=%',
        target_table,
        target_reason;
    END IF;
  END LOOP;
END $$;

-- Manual verification output: all rows should show `is_in_supabase_realtime = true`
-- after this SQL runs against an environment where the tables exist.
SELECT
  v.tablename AS table_name,
  v.reason,
  EXISTS (
    SELECT 1
    FROM pg_publication_tables pt
    WHERE pt.pubname = 'supabase_realtime'
      AND pt.schemaname = 'public'
      AND pt.tablename = v.tablename
  ) AS is_in_supabase_realtime
FROM (VALUES
  (
    'conversation_read_state',
    'DM unread badge/read cursor listener in iOS subscribes to read-state changes so badges can update after mark-read writes.'
  ),
  (
    'venue_event_vibes',
    'Fan Chat crowd reaction/vibe listeners subscribe to vibe changes for Discover previews and venue owner analytics.'
  ),
  (
    'venue_event_interests',
    'Venue owner analytics subscribes to Going/interest changes for owned event engagement refreshes.'
  ),
  (
    'venue_event_predictions',
    'Venue prediction modules subscribe to prediction row changes before debounced aggregate summary refresh.'
  ),
  (
    'pickup_games',
    'Following pickup activity subscribes to pickup game row updates for requester game cards.'
  )
) AS v(tablename, reason)
ORDER BY v.tablename;
