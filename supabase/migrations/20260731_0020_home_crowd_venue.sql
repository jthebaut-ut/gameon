-- Home Crowd: one venue per fan as their public home-base signal.

ALTER TABLE public.user_profiles
  ADD COLUMN IF NOT EXISTS home_crowd_venue_id uuid;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'user_profiles_home_crowd_venue_id_fkey'
  ) THEN
    ALTER TABLE public.user_profiles
      ADD CONSTRAINT user_profiles_home_crowd_venue_id_fkey
      FOREIGN KEY (home_crowd_venue_id)
      REFERENCES public.venues(id)
      ON DELETE SET NULL;
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_user_profiles_home_crowd_venue_id
  ON public.user_profiles (home_crowd_venue_id)
  WHERE home_crowd_venue_id IS NOT NULL;

COMMENT ON COLUMN public.user_profiles.home_crowd_venue_id IS
  'Optional single venue where this fan’s Home Crowd lives (sports bar, watch spot, pickup court, etc.).';

-- Public-safe venue summary (no owner email / private fields).
CREATE OR REPLACE FUNCTION public.home_crowd_venue_summary(p_venue_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT CASE
    WHEN p_venue_id IS NULL THEN NULL::jsonb
    ELSE (
      SELECT jsonb_build_object(
        'venue_id', v.id,
        'name', nullif(trim(coalesce(v.venue_name, '')), ''),
        'city_label', nullif(
          trim(
            coalesce(
              nullif(trim(coalesce(v.city, '')), ''),
              nullif(trim(split_part(coalesce(v.address, ''), ',', 1)), '')
            )
          ),
          ''
        ),
        'thumbnail_url', nullif(
          trim(coalesce(v.cover_photo_thumbnail_url, v.cover_photo_url, '')),
          ''
        )
      )
      FROM public.venues v
      WHERE v.id = p_venue_id
        AND COALESCE(lower(trim(v.admin_status)), 'active') = 'active'
      LIMIT 1
    )
  END;
$$;

CREATE OR REPLACE FUNCTION public.set_my_home_crowd_venue(p_venue_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_summary jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '28000';
  END IF;

  IF p_venue_id IS NULL THEN
    RAISE EXCEPTION 'venue_required' USING ERRCODE = '22023';
  END IF;

  v_summary := public.home_crowd_venue_summary(p_venue_id);
  IF v_summary IS NULL THEN
    RAISE EXCEPTION 'venue_not_found' USING ERRCODE = '22023';
  END IF;

  UPDATE public.user_profiles
  SET home_crowd_venue_id = p_venue_id
  WHERE id = v_uid;

  RETURN v_summary;
END;
$$;

CREATE OR REPLACE FUNCTION public.clear_my_home_crowd_venue()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '28000';
  END IF;

  UPDATE public.user_profiles
  SET home_crowd_venue_id = NULL
  WHERE id = v_uid;
END;
$$;

REVOKE ALL ON FUNCTION public.home_crowd_venue_summary(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.home_crowd_venue_summary(uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.set_my_home_crowd_venue(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_my_home_crowd_venue(uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.clear_my_home_crowd_venue() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.clear_my_home_crowd_venue() TO authenticated;

-- Extend public fan identity RPC with explicit home crowd (not inferred from favorites).
CREATE OR REPLACE FUNCTION public.get_public_fan_identity_profile(p_target_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_viewer uuid := auth.uid();
  v_target uuid := p_target_user_id;
  v_profile public.user_profiles%ROWTYPE;
  v_mutual_count int := 0;
  v_shared_teams int := 0;
  v_venue_count int := 0;
  v_pickup_hosted int := 0;
  v_pickup_joined int := 0;
BEGIN
  IF v_viewer IS NULL OR v_target IS NULL OR v_viewer = v_target THEN
    RETURN jsonb_build_object('visible', false);
  END IF;

  SELECT up.*
  INTO v_profile
  FROM public.user_profiles up
  WHERE up.id = v_target
    AND COALESCE(lower(trim(up.admin_status)), '') = 'active'
    AND up.admin_disabled_at IS NULL
    AND COALESCE(up.is_business_account, false) = false
    AND COALESCE(up.discoverable_by_fans, true) = true
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('visible', false);
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.blocked_users b
    WHERE (b.blocker_user_id = v_viewer AND b.blocked_user_id = v_target)
       OR (b.blocker_user_id = v_target AND b.blocked_user_id = v_viewer)
  ) THEN
    RETURN jsonb_build_object('visible', false);
  END IF;

  WITH viewer_friends AS (
    SELECT CASE
      WHEN f.requester_id = v_viewer THEN f.addressee_id
      ELSE f.requester_id
    END AS friend_id
    FROM public.friendships f
    WHERE f.status = 'accepted'
      AND (f.requester_id = v_viewer OR f.addressee_id = v_viewer)
  ),
  target_friends AS (
    SELECT CASE
      WHEN f.requester_id = v_target THEN f.addressee_id
      ELSE f.requester_id
    END AS friend_id
    FROM public.friendships f
    WHERE f.status = 'accepted'
      AND (f.requester_id = v_target OR f.addressee_id = v_target)
  ),
  mutual AS (
    SELECT vf.friend_id
    FROM viewer_friends vf
    INNER JOIN target_friends tf ON tf.friend_id = vf.friend_id
    WHERE vf.friend_id NOT IN (v_viewer, v_target)
  )
  SELECT count(*)::int INTO v_mutual_count FROM mutual;

  SELECT count(DISTINCT mine.team_id)::int
  INTO v_shared_teams
  FROM public.user_favorite_teams mine
  JOIN public.user_favorite_teams theirs
    ON theirs.team_id = mine.team_id
   AND theirs.user_id = v_target
  WHERE mine.user_id = v_viewer;

  SELECT count(*)::int
  INTO v_venue_count
  FROM public.favorite_venues fv
  WHERE lower(trim(coalesce(fv.user_email, ''))) = lower(trim(coalesce(v_profile.email, '')));

  SELECT count(*)::int
  INTO v_pickup_hosted
  FROM public.pickup_games pg
  WHERE pg.creator_user_id = v_target;

  SELECT count(*)::int
  INTO v_pickup_joined
  FROM public.pickup_game_requests pgr
  WHERE pgr.requester_user_id = v_target
    AND lower(trim(coalesce(pgr.status, ''))) = 'approved';

  RETURN jsonb_build_object(
    'visible', true,
    'user_id', v_target,
    'display_name', nullif(trim(coalesce(v_profile.display_name, '')), ''),
    'username', nullif(trim(coalesce(v_profile.username, '')), ''),
    'bio', nullif(trim(coalesce(v_profile.bio, '')), ''),
    'avatar_url', nullif(trim(coalesce(v_profile.avatar_url, '')), ''),
    'avatar_thumbnail_url', nullif(trim(coalesce(v_profile.avatar_thumbnail_url, '')), ''),
    'member_since', v_profile.created_at,
    'fan_identity_preferences', COALESCE(v_profile.fan_identity_preferences, '{}'::jsonb),
    'home_crowd_venue', public.home_crowd_venue_summary(v_profile.home_crowd_venue_id),
    'favorite_team_ids', COALESCE(
      (
        SELECT jsonb_agg(uft.team_id ORDER BY uft.team_id)
        FROM public.user_favorite_teams uft
        WHERE uft.user_id = v_target
      ),
      '[]'::jsonb
    ),
    'shared_team_ids', COALESCE(
      (
        SELECT jsonb_agg(DISTINCT mine.team_id ORDER BY mine.team_id)
        FROM public.user_favorite_teams mine
        JOIN public.user_favorite_teams theirs
          ON theirs.team_id = mine.team_id
         AND theirs.user_id = v_target
        WHERE mine.user_id = v_viewer
      ),
      '[]'::jsonb
    ),
    'mutual_fans_count', v_mutual_count,
    'shared_teams_count', v_shared_teams,
    'venue_count', v_venue_count,
    'pickup_hosted_count', v_pickup_hosted,
    'pickup_joined_count', v_pickup_joined,
    'mutual_fan_avatars', COALESCE(
      (
        SELECT jsonb_agg(
          jsonb_build_object(
            'user_id', up.id,
            'display_name', nullif(trim(coalesce(up.display_name, '')), ''),
            'avatar_url', nullif(trim(coalesce(up.avatar_thumbnail_url, up.avatar_url, '')), '')
          )
          ORDER BY up.display_name NULLS LAST, up.id
        )
        FROM (
          SELECT vf.friend_id
          FROM viewer_friends vf
          INNER JOIN target_friends tf ON tf.friend_id = vf.friend_id
          WHERE vf.friend_id NOT IN (v_viewer, v_target)
          LIMIT 4
        ) m
        JOIN public.user_profiles up ON up.id = m.friend_id
        WHERE COALESCE(lower(trim(up.admin_status)), '') = 'active'
          AND COALESCE(up.discoverable_by_fans, true) = true
      ),
      '[]'::jsonb
    ),
    'venue_cards', COALESCE(
      (
        SELECT jsonb_agg(
          jsonb_build_object(
            'venue_id', v.id,
            'venue_name', nullif(trim(coalesce(v.venue_name, '')), ''),
            'city_label', nullif(trim(coalesce(v.city, '')), ''),
            'thumbnail_url', nullif(trim(coalesce(v.cover_photo_thumbnail_url, v.cover_photo_url, '')), '')
          )
          ORDER BY fv.id DESC
        )
        FROM (
          SELECT fv.venue_id, fv.id
          FROM public.favorite_venues fv
          WHERE lower(trim(coalesce(fv.user_email, ''))) = lower(trim(coalesce(v_profile.email, '')))
          ORDER BY fv.id DESC
          LIMIT 3
        ) fv
        JOIN public.venues v ON v.id = fv.venue_id
        WHERE COALESCE(lower(trim(v.admin_status)), 'active') = 'active'
      ),
      '[]'::jsonb
    )
  );
END;
$$;

COMMENT ON FUNCTION public.set_my_home_crowd_venue(uuid) IS
  'Sets the signed-in fan''s single Home Crowd venue (replaces any previous selection).';

COMMENT ON FUNCTION public.clear_my_home_crowd_venue() IS
  'Clears the signed-in fan''s Home Crowd venue.';
