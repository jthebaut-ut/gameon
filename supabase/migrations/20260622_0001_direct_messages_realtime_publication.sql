-- Ensure direct_messages is in the Supabase Realtime publication so Postgres INSERT/UPDATE/DELETE
-- changes can be streamed to clients (required for DM live updates).

DO $pub$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_publication_tables pt
    WHERE pt.pubname = 'supabase_realtime'
      AND pt.schemaname = 'public'
      AND pt.tablename = 'direct_messages'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.direct_messages;
  END IF;
END
$pub$;
