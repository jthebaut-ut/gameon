-- Read-only diagnostics for DM Realtime (run in Supabase SQL Editor).
-- 1) Publication membership
SELECT *
FROM pg_publication_tables
WHERE pubname = 'supabase_realtime'
  AND schemaname = 'public'
  AND tablename = 'direct_messages';

-- 2) RLS enabled?
SELECT c.relname, c.relrowsecurity AS rls_enabled, c.relforcerowsecurity AS rls_forced
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relname = 'direct_messages';

-- 3) Policies on direct_messages
SELECT schemaname, tablename, policyname, cmd AS command, qual AS using_expression
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename = 'direct_messages'
ORDER BY policyname;
