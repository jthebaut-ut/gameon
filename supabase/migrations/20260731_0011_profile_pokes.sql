-- Repeatable profile Pokes (separate from one-per-pair profile_likes / Fan Props).

CREATE TABLE IF NOT EXISTS public.profile_pokes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  poker_user_id uuid NOT NULL REFERENCES public.user_profiles (id) ON DELETE CASCADE,
  poked_user_id uuid NOT NULL REFERENCES public.user_profiles (id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  source text NOT NULL DEFAULT 'profile',
  CONSTRAINT profile_pokes_no_self_poke CHECK (poker_user_id <> poked_user_id)
);

CREATE INDEX IF NOT EXISTS profile_pokes_poked_created_idx
  ON public.profile_pokes (poked_user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS profile_pokes_poker_created_idx
  ON public.profile_pokes (poker_user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS profile_pokes_pair_created_idx
  ON public.profile_pokes (poker_user_id, poked_user_id, created_at DESC);

ALTER TABLE public.profile_pokes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS profile_pokes_insert_own_unblocked ON public.profile_pokes;
CREATE POLICY profile_pokes_insert_own_unblocked
  ON public.profile_pokes FOR INSERT TO authenticated
  WITH CHECK (
    poker_user_id = auth.uid()
    AND NOT EXISTS (
      SELECT 1
      FROM public.blocked_users b
      WHERE (b.blocker_user_id = poker_user_id AND b.blocked_user_id = poked_user_id)
         OR (b.blocker_user_id = poked_user_id AND b.blocked_user_id = poker_user_id)
    )
  );

DROP POLICY IF EXISTS profile_pokes_select_involved_unblocked ON public.profile_pokes;
CREATE POLICY profile_pokes_select_involved_unblocked
  ON public.profile_pokes FOR SELECT TO authenticated
  USING (
    (poker_user_id = auth.uid() OR poked_user_id = auth.uid())
    AND NOT EXISTS (
      SELECT 1
      FROM public.blocked_users b
      WHERE (b.blocker_user_id = poker_user_id AND b.blocked_user_id = poked_user_id)
         OR (b.blocker_user_id = poked_user_id AND b.blocked_user_id = poker_user_id)
    )
  );

GRANT SELECT, INSERT ON public.profile_pokes TO authenticated;

COMMENT ON TABLE public.profile_pokes IS
  'Repeatable profile poke events. Fan Props remain on profile_likes until UI migration.';

COMMENT ON COLUMN public.profile_pokes.source IS
  'Origin of the poke action, e.g. profile.';

-- ---------------------------------------------------------------------------
-- Helpers (SECURITY DEFINER)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.profile_pokes_is_block_between(p_user_a uuid, p_user_b uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.blocked_users b
    WHERE (b.blocker_user_id = p_user_a AND b.blocked_user_id = p_user_b)
       OR (b.blocker_user_id = p_user_b AND b.blocked_user_id = p_user_a)
  );
$$;

CREATE OR REPLACE FUNCTION public.profile_pokes_is_pokeable_fan(p_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.user_profiles up
    WHERE up.id = p_user_id
      AND COALESCE(lower(trim(up.admin_status)), '') = 'active'
      AND up.admin_disabled_at IS NULL
      AND COALESCE(up.is_business_account, false) = false
  );
$$;

REVOKE ALL ON FUNCTION public.profile_pokes_is_block_between(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.profile_pokes_is_pokeable_fan(uuid) FROM PUBLIC;

-- ---------------------------------------------------------------------------
-- poke_profile: insert with 15-minute per-pair cooldown
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.poke_profile(p_target_user_id uuid)
RETURNS TABLE (
  poke_id uuid,
  created_at timestamptz,
  viewer_can_poke_now boolean,
  viewer_cooldown_ends_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  last_poke_at timestamptz;
  cooldown_ends timestamptz;
  inserted public.profile_pokes%ROWTYPE;
  cooldown_interval interval := interval '15 minutes';
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  IF p_target_user_id IS NULL THEN
    RAISE EXCEPTION 'Target user is required.';
  END IF;

  IF p_target_user_id = me THEN
    RAISE EXCEPTION 'You cannot poke yourself.';
  END IF;

  IF NOT public.profile_pokes_is_pokeable_fan(me) THEN
    RAISE EXCEPTION 'Your account cannot send pokes right now.';
  END IF;

  IF NOT public.profile_pokes_is_pokeable_fan(p_target_user_id) THEN
    RAISE EXCEPTION 'This profile cannot receive pokes.';
  END IF;

  IF public.profile_pokes_is_block_between(me, p_target_user_id) THEN
    RAISE EXCEPTION 'You cannot poke this user.';
  END IF;

  SELECT pp.created_at
  INTO last_poke_at
  FROM public.profile_pokes pp
  WHERE pp.poker_user_id = me
    AND pp.poked_user_id = p_target_user_id
  ORDER BY pp.created_at DESC
  LIMIT 1;

  IF last_poke_at IS NOT NULL THEN
    cooldown_ends := last_poke_at + cooldown_interval;
    IF cooldown_ends > now() THEN
      RETURN QUERY
      SELECT
        NULL::uuid,
        NULL::timestamptz,
        false,
        cooldown_ends;
      RETURN;
    END IF;
  END IF;

  INSERT INTO public.profile_pokes (poker_user_id, poked_user_id, source)
  VALUES (me, p_target_user_id, 'profile')
  RETURNING * INTO inserted;

  cooldown_ends := inserted.created_at + cooldown_interval;

  RETURN QUERY
  SELECT
    inserted.id,
    inserted.created_at,
    false,
    cooldown_ends;
END;
$$;

REVOKE ALL ON FUNCTION public.poke_profile(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.poke_profile(uuid) TO authenticated;

COMMENT ON FUNCTION public.poke_profile(uuid) IS
  'Authenticated fan pokes a profile. Enforces blocks, active non-business profiles, and 15-minute cooldown per pair.';

-- ---------------------------------------------------------------------------
-- get_profile_poke_summary: aggregate counts + viewer cooldown state
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.get_profile_poke_summary(p_target_user_id uuid)
RETURNS TABLE (
  total_pokes bigint,
  unique_pokers bigint,
  viewer_last_poked_at timestamptz,
  viewer_can_poke_now boolean,
  viewer_cooldown_ends_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  last_poke_at timestamptz;
  cooldown_ends timestamptz;
  cooldown_interval interval := interval '15 minutes';
  can_poke boolean := false;
BEGIN
  IF p_target_user_id IS NULL THEN
    RAISE EXCEPTION 'Target user is required.';
  END IF;

  SELECT
    COUNT(*)::bigint,
    COUNT(DISTINCT pp.poker_user_id)::bigint
  INTO total_pokes, unique_pokers
  FROM public.profile_pokes pp
  WHERE pp.poked_user_id = p_target_user_id
    AND (
      me IS NULL
      OR NOT public.profile_pokes_is_block_between(me, pp.poker_user_id)
    );

  viewer_last_poked_at := NULL;
  viewer_cooldown_ends_at := NULL;

  IF me IS NOT NULL AND me <> p_target_user_id THEN
    SELECT pp.created_at
    INTO last_poke_at
    FROM public.profile_pokes pp
    WHERE pp.poker_user_id = me
      AND pp.poked_user_id = p_target_user_id
    ORDER BY pp.created_at DESC
    LIMIT 1;

    viewer_last_poked_at := last_poke_at;

    IF last_poke_at IS NOT NULL THEN
      cooldown_ends := last_poke_at + cooldown_interval;
      IF cooldown_ends > now() THEN
        viewer_cooldown_ends_at := cooldown_ends;
      END IF;
    END IF;

    can_poke :=
      public.profile_pokes_is_pokeable_fan(me)
      AND public.profile_pokes_is_pokeable_fan(p_target_user_id)
      AND NOT public.profile_pokes_is_block_between(me, p_target_user_id)
      AND viewer_cooldown_ends_at IS NULL;
  END IF;

  viewer_can_poke_now := can_poke;

  RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION public.get_profile_poke_summary(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_profile_poke_summary(uuid) TO authenticated;

COMMENT ON FUNCTION public.get_profile_poke_summary(uuid) IS
  'Poke totals for a profile plus whether auth.uid() can poke now (15-minute cooldown).';
