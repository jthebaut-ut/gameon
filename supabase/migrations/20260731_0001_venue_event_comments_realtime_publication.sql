DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_publication_tables pt
    WHERE pt.pubname = 'supabase_realtime'
      AND pt.schemaname = 'public'
      AND pt.tablename = 'venue_event_comments'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.venue_event_comments;
  END IF;
END $$;
