-- Fan self-service for venue_event_interests (Going / Interested).
-- Upsert requires INSERT + UPDATE policies; the app uses insert-or-duplicate-success for Going.

ALTER TABLE public.venue_event_interests ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS venue_event_interests_select_authenticated ON public.venue_event_interests;
CREATE POLICY venue_event_interests_select_authenticated
  ON public.venue_event_interests
  FOR SELECT
  TO authenticated
  USING (true);

DROP POLICY IF EXISTS venue_event_interests_insert_own ON public.venue_event_interests;
CREATE POLICY venue_event_interests_insert_own
  ON public.venue_event_interests
  FOR INSERT
  TO authenticated
  WITH CHECK (
    lower(btrim(user_email)) = lower(btrim(coalesce(auth.jwt() ->> 'email', '')))
    AND interest_status IN ('going', 'interested')
  );

DROP POLICY IF EXISTS venue_event_interests_update_own ON public.venue_event_interests;
CREATE POLICY venue_event_interests_update_own
  ON public.venue_event_interests
  FOR UPDATE
  TO authenticated
  USING (
    lower(btrim(user_email)) = lower(btrim(coalesce(auth.jwt() ->> 'email', '')))
  )
  WITH CHECK (
    lower(btrim(user_email)) = lower(btrim(coalesce(auth.jwt() ->> 'email', '')))
    AND interest_status IN ('going', 'interested')
  );

DROP POLICY IF EXISTS venue_event_interests_delete_own ON public.venue_event_interests;
CREATE POLICY venue_event_interests_delete_own
  ON public.venue_event_interests
  FOR DELETE
  TO authenticated
  USING (
    lower(btrim(user_email)) = lower(btrim(coalesce(auth.jwt() ->> 'email', '')))
  );
