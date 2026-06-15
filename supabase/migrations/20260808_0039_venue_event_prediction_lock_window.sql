-- Server-side voting lock for venue game predictions.
-- Fans may create, update, or remove predictions until 10 minutes after the
-- venue event's scheduled start time. Prior predictions remain readable.

CREATE OR REPLACE FUNCTION public.venue_event_prediction_voting_open(p_venue_event_id uuid)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_start_at timestamptz;
  v_event_date text;
  v_event_time text;
BEGIN
  SELECT ve.scheduled_start_at, ve.event_date::text, ve.event_time
    INTO v_start_at, v_event_date, v_event_time
  FROM public.venue_events ve
  WHERE ve.id = p_venue_event_id;

  IF v_start_at IS NULL AND NULLIF(btrim(COALESCE(v_event_date, '')), '') IS NOT NULL THEN
    BEGIN
      v_start_at :=
        (v_event_date::date + COALESCE(NULLIF(btrim(COALESCE(v_event_time, '')), '')::time, time '12:00'))::timestamptz;
    EXCEPTION WHEN others THEN
      v_start_at := NULL;
    END;
  END IF;

  RETURN v_start_at IS NULL OR now() <= (v_start_at + interval '10 minutes');
END;
$$;

REVOKE ALL ON FUNCTION public.venue_event_prediction_voting_open(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.venue_event_prediction_voting_open(uuid) TO authenticated;

DROP POLICY IF EXISTS venue_event_predictions_insert_own ON public.venue_event_predictions;
CREATE POLICY venue_event_predictions_insert_own
  ON public.venue_event_predictions
  FOR INSERT
  TO authenticated
  WITH CHECK (
    user_id = auth.uid()
    AND public.venue_event_prediction_voting_open(venue_event_id)
    AND EXISTS (
      SELECT 1
      FROM public.venue_events ve
      WHERE ve.id = venue_event_id
        AND COALESCE(ve.admin_status, 'active') = 'active'
    )
  );

DROP POLICY IF EXISTS venue_event_predictions_update_own ON public.venue_event_predictions;
CREATE POLICY venue_event_predictions_update_own
  ON public.venue_event_predictions
  FOR UPDATE
  TO authenticated
  USING (
    user_id = auth.uid()
    AND public.venue_event_prediction_voting_open(venue_event_id)
  )
  WITH CHECK (
    user_id = auth.uid()
    AND public.venue_event_prediction_voting_open(venue_event_id)
  );

DROP POLICY IF EXISTS venue_event_predictions_delete_own ON public.venue_event_predictions;
CREATE POLICY venue_event_predictions_delete_own
  ON public.venue_event_predictions
  FOR DELETE
  TO authenticated
  USING (
    user_id = auth.uid()
    AND public.venue_event_prediction_voting_open(venue_event_id)
  );

COMMENT ON FUNCTION public.venue_event_prediction_voting_open(uuid) IS
  'Returns true until venue_events.scheduled_start_at plus 10 minutes. Used by prediction RLS to enforce server-time voting lock.';
