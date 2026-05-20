-- Lightweight pre-game predictions for structured venue games.

ALTER TABLE public.venue_events
  ADD COLUMN IF NOT EXISTS home_team text,
  ADD COLUMN IF NOT EXISTS away_team text;

COMMENT ON COLUMN public.venue_events.home_team IS
  'Structured home team for imported venue games and future supported manual structured entries.';
COMMENT ON COLUMN public.venue_events.away_team IS
  'Structured away team for imported venue games and future supported manual structured entries.';

CREATE TABLE IF NOT EXISTS public.venue_event_predictions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  venue_event_id uuid NOT NULL REFERENCES public.venue_events(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  prediction_type text NOT NULL,
  predicted_winner text,
  predicted_home_score int,
  predicted_away_score int,
  predicted_first_score_team text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT venue_event_predictions_type_check CHECK (
    prediction_type IN ('winner', 'score', 'first_score_team')
  ),
  CONSTRAINT venue_event_predictions_unique_user_type UNIQUE (
    venue_event_id,
    user_id,
    prediction_type
  )
);

CREATE INDEX IF NOT EXISTS idx_venue_event_predictions_event_type
  ON public.venue_event_predictions (venue_event_id, prediction_type);

CREATE INDEX IF NOT EXISTS idx_venue_event_predictions_user
  ON public.venue_event_predictions (user_id, updated_at DESC);

CREATE OR REPLACE FUNCTION public.set_venue_event_prediction_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_venue_event_predictions_updated_at ON public.venue_event_predictions;
CREATE TRIGGER trg_venue_event_predictions_updated_at
BEFORE UPDATE ON public.venue_event_predictions
FOR EACH ROW
EXECUTE FUNCTION public.set_venue_event_prediction_updated_at();

ALTER TABLE public.venue_event_predictions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS venue_event_predictions_select_visible_events ON public.venue_event_predictions;
CREATE POLICY venue_event_predictions_select_visible_events
  ON public.venue_event_predictions
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.venue_events ve
      WHERE ve.id = venue_event_id
        AND COALESCE(ve.admin_status, 'active') = 'active'
    )
  );

DROP POLICY IF EXISTS venue_event_predictions_insert_own ON public.venue_event_predictions;
CREATE POLICY venue_event_predictions_insert_own
  ON public.venue_event_predictions
  FOR INSERT
  TO authenticated
  WITH CHECK (
    user_id = auth.uid()
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
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS venue_event_predictions_delete_own ON public.venue_event_predictions;
CREATE POLICY venue_event_predictions_delete_own
  ON public.venue_event_predictions
  FOR DELETE
  TO authenticated
  USING (user_id = auth.uid());
