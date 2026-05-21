-- Recipient-only hide for incoming Pokes history.
-- Keeps poke rows intact so sender cooldowns, friendships, and other profile systems are unaffected.

CREATE TABLE IF NOT EXISTS public.profile_pokes_recipient_clear (
  user_id uuid PRIMARY KEY REFERENCES auth.users (id) ON DELETE CASCADE,
  cleared_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.profile_pokes_recipient_clear ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS profile_pokes_recipient_clear_select_own ON public.profile_pokes_recipient_clear;
CREATE POLICY profile_pokes_recipient_clear_select_own
  ON public.profile_pokes_recipient_clear FOR SELECT TO authenticated
  USING (user_id = auth.uid());

DROP POLICY IF EXISTS profile_pokes_recipient_clear_upsert_own ON public.profile_pokes_recipient_clear;
CREATE POLICY profile_pokes_recipient_clear_upsert_own
  ON public.profile_pokes_recipient_clear FOR INSERT TO authenticated
  WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS profile_pokes_recipient_clear_update_own ON public.profile_pokes_recipient_clear;
CREATE POLICY profile_pokes_recipient_clear_update_own
  ON public.profile_pokes_recipient_clear FOR UPDATE TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

GRANT SELECT, INSERT, UPDATE ON public.profile_pokes_recipient_clear TO authenticated;

COMMENT ON TABLE public.profile_pokes_recipient_clear IS
  'When set, hides incoming Pokes created at or before cleared_at from the recipient profile/history only.';
