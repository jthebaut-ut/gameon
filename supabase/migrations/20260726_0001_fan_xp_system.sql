-- Fan Level / XP MVP: user_xp summary + deduplicated xp_events ledger.

CREATE TABLE IF NOT EXISTS public.user_xp (
  user_id uuid PRIMARY KEY REFERENCES auth.users (id) ON DELETE CASCADE,
  total_xp integer NOT NULL DEFAULT 0 CHECK (total_xp >= 0),
  level integer NOT NULL DEFAULT 1 CHECK (level >= 1),
  title text NOT NULL DEFAULT 'Rookie Fan',
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.xp_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  xp_amount integer NOT NULL CHECK (xp_amount > 0),
  source text NOT NULL,
  source_id uuid,
  source_key text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT xp_events_source_key_present CHECK (
    source_id IS NOT NULL OR nullif(trim(source_key), '') IS NOT NULL
  )
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_xp_events_user_source_dedup
  ON public.xp_events (user_id, source, COALESCE(source_id::text, source_key));

CREATE INDEX IF NOT EXISTS idx_xp_events_user_created
  ON public.xp_events (user_id, created_at DESC);

ALTER TABLE public.user_xp ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.xp_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS user_xp_select_own ON public.user_xp;
CREATE POLICY user_xp_select_own
  ON public.user_xp FOR SELECT TO authenticated
  USING (user_id = auth.uid());

DROP POLICY IF EXISTS xp_events_select_own ON public.xp_events;
CREATE POLICY xp_events_select_own
  ON public.xp_events FOR SELECT TO authenticated
  USING (user_id = auth.uid());

-- Level thresholds (anchor levels); linear interpolation between anchors.
CREATE OR REPLACE FUNCTION public.fan_xp_threshold_for_level(p_level integer)
RETURNS integer
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  l integer := greatest(1, coalesce(p_level, 1));
BEGIN
  IF l <= 1 THEN RETURN 0; END IF;
  IF l = 2 THEN RETURN 100; END IF;
  IF l = 3 THEN RETURN 250; END IF;
  IF l = 4 THEN RETURN 450; END IF;
  IF l = 5 THEN RETURN 700; END IF;
  IF l <= 9 THEN
    RETURN 700 + ((3000 - 700) * (l - 5)) / 4;
  END IF;
  IF l = 10 THEN RETURN 3000; END IF;
  IF l <= 14 THEN
    RETURN 3000 + ((8000 - 3000) * (l - 10)) / 4;
  END IF;
  IF l = 15 THEN RETURN 8000; END IF;
  IF l <= 19 THEN
    RETURN 8000 + ((15000 - 8000) * (l - 15)) / 4;
  END IF;
  IF l = 20 THEN RETURN 15000; END IF;
  IF l <= 29 THEN
    RETURN 15000 + ((40000 - 15000) * (l - 20)) / 9;
  END IF;
  IF l = 30 THEN RETURN 40000; END IF;
  IF l <= 49 THEN
    RETURN 40000 + ((120000 - 40000) * (l - 30)) / 19;
  END IF;
  RETURN 120000;
END;
$$;

CREATE OR REPLACE FUNCTION public.fan_xp_level_for_total(p_total integer)
RETURNS integer
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  total integer := greatest(0, coalesce(p_total, 0));
  lvl integer := 1;
BEGIN
  WHILE lvl < 50 AND total >= public.fan_xp_threshold_for_level(lvl + 1) LOOP
    lvl := lvl + 1;
  END LOOP;
  IF total >= 120000 THEN
    lvl := 50;
  END IF;
  RETURN lvl;
END;
$$;

CREATE OR REPLACE FUNCTION public.fan_xp_title_for_level(p_level integer)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN coalesce(p_level, 1) >= 40 THEN 'FanGeo Elite'
    WHEN p_level >= 25 THEN 'Hardcore Supporter'
    WHEN p_level >= 15 THEN 'Stadium Legend'
    WHEN p_level >= 10 THEN 'Super Fan'
    WHEN p_level >= 5 THEN 'Loyal Fan'
    ELSE 'Rookie Fan'
  END;
$$;

CREATE OR REPLACE FUNCTION public.ensure_user_xp_row(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.user_xp (user_id, total_xp, level, title)
  VALUES (p_user_id, 0, 1, public.fan_xp_title_for_level(1))
  ON CONFLICT (user_id) DO NOTHING;
END;
$$;

CREATE OR REPLACE FUNCTION public.award_fan_xp(
  p_user_id uuid,
  p_amount integer,
  p_source text,
  p_source_id uuid DEFAULT NULL,
  p_source_key text DEFAULT ''
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  src text := lower(trim(coalesce(p_source, '')));
  key text := coalesce(p_source_id::text, nullif(trim(coalesce(p_source_key, '')), ''));
  inserted_id uuid;
  row public.user_xp%ROWTYPE;
  new_total integer;
  new_level integer;
  new_title text;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;
  IF p_user_id IS NULL OR p_amount IS NULL OR p_amount <= 0 OR src = '' OR key IS NULL THEN
    RETURN jsonb_build_object('awarded', false, 'reason', 'invalid_input');
  END IF;

  IF p_user_id IS DISTINCT FROM me THEN
    IF src = 'pickup_join_approved' AND p_source_id IS NOT NULL THEN
      IF NOT EXISTS (
        SELECT 1
        FROM public.pickup_game_requests pgr
        JOIN public.pickup_games pg ON pg.id = pgr.pickup_game_id
        WHERE pgr.id = p_source_id
          AND pg.creator_user_id = me
          AND pgr.requester_user_id = p_user_id
      ) THEN
        RAISE EXCEPTION 'Not allowed to award pickup join XP for this user.';
      END IF;
    ELSIF src = 'friend_connected' AND p_source_id IS NOT NULL THEN
      IF NOT EXISTS (
        SELECT 1
        FROM public.friendships f
        WHERE f.id = p_source_id
          AND f.status = 'accepted'
          AND (
            (f.requester_id = me AND f.addressee_id = p_user_id)
            OR (f.addressee_id = me AND f.requester_id = p_user_id)
          )
      ) THEN
        RAISE EXCEPTION 'Not allowed to award friend XP for this user.';
      END IF;
    ELSE
      RAISE EXCEPTION 'Not allowed to award XP for another user.';
    END IF;
  END IF;

  PERFORM public.ensure_user_xp_row(p_user_id);

  INSERT INTO public.xp_events (user_id, xp_amount, source, source_id, source_key)
  VALUES (
    p_user_id,
    p_amount,
    src,
    p_source_id,
    CASE WHEN p_source_id IS NULL THEN trim(coalesce(p_source_key, '')) ELSE '' END
  )
  ON CONFLICT DO NOTHING
  RETURNING id INTO inserted_id;

  IF inserted_id IS NULL THEN
    SELECT * INTO row FROM public.user_xp WHERE user_id = p_user_id;
    RETURN jsonb_build_object(
      'awarded', false,
      'duplicate', true,
      'total_xp', row.total_xp,
      'level', row.level,
      'title', row.title,
      'xp_gained', 0
    );
  END IF;

  SELECT total_xp + p_amount INTO new_total FROM public.user_xp WHERE user_id = p_user_id;
  new_level := public.fan_xp_level_for_total(new_total);
  new_title := public.fan_xp_title_for_level(new_level);

  UPDATE public.user_xp
  SET total_xp = new_total,
      level = new_level,
      title = new_title,
      updated_at = now()
  WHERE user_id = p_user_id
  RETURNING * INTO row;

  RETURN jsonb_build_object(
    'awarded', true,
    'duplicate', false,
    'total_xp', row.total_xp,
    'level', row.level,
    'title', row.title,
    'xp_gained', p_amount
  );
END;
$$;

REVOKE ALL ON FUNCTION public.award_fan_xp(uuid, integer, text, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.award_fan_xp(uuid, integer, text, uuid, text) TO authenticated;

REVOKE ALL ON FUNCTION public.ensure_user_xp_row(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.ensure_user_xp_row(uuid) TO authenticated;

COMMENT ON TABLE public.user_xp IS 'Fan Level summary per auth user.';
COMMENT ON TABLE public.xp_events IS 'Deduplicated XP ledger; one row per user/source/source_id|source_key.';
