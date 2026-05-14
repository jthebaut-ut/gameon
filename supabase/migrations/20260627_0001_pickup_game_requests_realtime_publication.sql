-- Add pickup_game_requests to the Supabase Realtime publication so creators can receive
-- INSERT/UPDATE events for join requests on games they own (RLS applies to visible rows).

DO $pub$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_publication_tables pt
    WHERE pt.pubname = 'supabase_realtime'
      AND pt.schemaname = 'public'
      AND pt.tablename = 'pickup_game_requests'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.pickup_game_requests;
  END IF;
END
$pub$;
