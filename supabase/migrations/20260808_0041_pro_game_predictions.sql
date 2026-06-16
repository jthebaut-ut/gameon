-- Pre-game predictions for saved Pro Games (soccer and hockey).

CREATE TABLE IF NOT EXISTS public.pro_game_predictions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pro_game_id text NOT NULL,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  prediction_type text NOT NULL,
  predicted_winner text,
  predicted_home_score int,
  predicted_away_score int,
  predicted_first_score_team text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pro_game_predictions_type_check CHECK (
    prediction_type IN ('winner', 'score', 'first_score_team')
  ),
  CONSTRAINT pro_game_predictions_unique_user_type UNIQUE (
    pro_game_id,
    user_id,
    prediction_type
  )
);

CREATE INDEX IF NOT EXISTS idx_pro_game_predictions_game_type
  ON public.pro_game_predictions (pro_game_id, prediction_type);

CREATE INDEX IF NOT EXISTS idx_pro_game_predictions_user
  ON public.pro_game_predictions (user_id, updated_at DESC);

CREATE OR REPLACE FUNCTION public.set_pro_game_prediction_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_pro_game_predictions_updated_at ON public.pro_game_predictions;
CREATE TRIGGER trg_pro_game_predictions_updated_at
BEFORE UPDATE ON public.pro_game_predictions
FOR EACH ROW
EXECUTE FUNCTION public.set_pro_game_prediction_updated_at();

CREATE OR REPLACE FUNCTION public.pro_game_prediction_voting_open(p_pro_game_id text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_start_at timestamptz;
BEGIN
  SELECT lm.start_time
    INTO v_start_at
  FROM public.live_matches lm
  WHERE lm.id = btrim(p_pro_game_id)
  LIMIT 1;

  RETURN v_start_at IS NULL OR now() <= (v_start_at + interval '10 minutes');
END;
$$;

REVOKE ALL ON FUNCTION public.pro_game_prediction_voting_open(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pro_game_prediction_voting_open(text) TO authenticated;

ALTER TABLE public.pro_game_predictions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS pro_game_predictions_select_authenticated ON public.pro_game_predictions;
CREATE POLICY pro_game_predictions_select_authenticated
  ON public.pro_game_predictions
  FOR SELECT
  TO authenticated
  USING (true);

DROP POLICY IF EXISTS pro_game_predictions_insert_own ON public.pro_game_predictions;
CREATE POLICY pro_game_predictions_insert_own
  ON public.pro_game_predictions
  FOR INSERT
  TO authenticated
  WITH CHECK (
    user_id = auth.uid()
    AND public.pro_game_prediction_voting_open(pro_game_id)
  );

DROP POLICY IF EXISTS pro_game_predictions_update_own ON public.pro_game_predictions;
CREATE POLICY pro_game_predictions_update_own
  ON public.pro_game_predictions
  FOR UPDATE
  TO authenticated
  USING (
    user_id = auth.uid()
    AND public.pro_game_prediction_voting_open(pro_game_id)
  )
  WITH CHECK (
    user_id = auth.uid()
    AND public.pro_game_prediction_voting_open(pro_game_id)
  );

DROP POLICY IF EXISTS pro_game_predictions_delete_own ON public.pro_game_predictions;
CREATE POLICY pro_game_predictions_delete_own
  ON public.pro_game_predictions
  FOR DELETE
  TO authenticated
  USING (user_id = auth.uid());

COMMENT ON TABLE public.pro_game_predictions IS
  'Fan predictions for saved Pro Games. Voting locks 10 minutes after live_matches.start_time.';
COMMENT ON FUNCTION public.pro_game_prediction_voting_open(text) IS
  'Returns true until live_matches.start_time plus 10 minutes for the given pro_game_id.';

DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE public.pro_game_predictions;
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;
