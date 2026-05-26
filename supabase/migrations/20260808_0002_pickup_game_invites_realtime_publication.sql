-- Incoming pickup invites need recipient-side realtime so Going badges and invite cards
-- refresh without requiring a tab switch or foreground reload.

DO $pub$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_publication_tables pt
    WHERE pt.pubname = 'supabase_realtime'
      AND pt.schemaname = 'public'
      AND pt.tablename = 'pickup_game_invites'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.pickup_game_invites;
  END IF;
END
$pub$;

-- DELETE payloads need the previous invite row so the client can match invitee_user_id
-- before refreshing recipient badges.
ALTER TABLE public.pickup_game_invites REPLICA IDENTITY FULL;
