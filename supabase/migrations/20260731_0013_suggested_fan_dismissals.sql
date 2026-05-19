-- Suggested Fans: persisted dismissals + ranked RPC (pool up to 30 for client; display 10).

CREATE TABLE IF NOT EXISTS public.suggested_fan_dismissals (
  user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  dismissed_user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  dismissed_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT suggested_fan_dismissals_pkey PRIMARY KEY (user_id, dismissed_user_id),
  CONSTRAINT suggested_fan_dismissals_not_self CHECK (user_id <> dismissed_user_id)
);

CREATE INDEX IF NOT EXISTS idx_suggested_fan_dismissals_user_dismissed_at
  ON public.suggested_fan_dismissals (user_id, dismissed_at DESC);

ALTER TABLE public.suggested_fan_dismissals ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS suggested_fan_dismissals_select_own ON public.suggested_fan_dismissals;
CREATE POLICY suggested_fan_dismissals_select_own
  ON public.suggested_fan_dismissals FOR SELECT TO authenticated
  USING (user_id = auth.uid());

DROP POLICY IF EXISTS suggested_fan_dismissals_insert_own ON public.suggested_fan_dismissals;
CREATE POLICY suggested_fan_dismissals_insert_own
  ON public.suggested_fan_dismissals FOR INSERT TO authenticated
  WITH CHECK (user_id = auth.uid());

CREATE OR REPLACE FUNCTION public.get_profile_friend_suggestions(
  p_limit int DEFAULT 30,
  p_radius_miles numeric DEFAULT 20,
  p_center_lat double precision DEFAULT NULL,
  p_center_lng double precision DEFAULT NULL
)
RETURNS TABLE (
  user_id uuid,
  display_name text,
  username text,
  avatar_url text,
  avatar_thumbnail_url text,
  reason_type text,
  reason_label text,
  score int
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH params AS (
    SELECT
      auth.uid() AS viewer_id,
      LEAST(GREATEST(COALESCE(p_limit, 30), 1), 50)::int AS result_limit,
      GREATEST(COALESCE(p_radius_miles, 20), 0)::double precision AS radius_miles,
      p_center_lat AS center_lat,
      p_center_lng AS center_lng,
      (p_center_lat IS NOT NULL AND p_center_lng IS NOT NULL) AS has_center
  ),
  viewer_profile AS (
    SELECT
      up.id,
      lower(trim(coalesce(up.email, ''))) AS email_norm
    FROM public.user_profiles up
    JOIN params p ON p.viewer_id = up.id
    WHERE COALESCE(lower(trim(up.admin_status)), '') = 'active'
      AND up.admin_disabled_at IS NULL
      AND COALESCE(up.is_business_account, false) = false
  ),
  viewer_friends AS (
    SELECT DISTINCT
      CASE
        WHEN f.requester_id = vp.id THEN f.addressee_id
        ELSE f.requester_id
      END AS friend_user_id
    FROM viewer_profile vp
    JOIN public.friendships f
      ON f.status = 'accepted'
     AND COALESCE(f.requester_entity_type, 'user') = 'user'
     AND COALESCE(f.addressee_entity_type, 'user') = 'user'
     AND (f.requester_id = vp.id OR f.addressee_id = vp.id)
  ),
  pickup_participants AS (
    SELECT
      pg.id AS pickup_game_id,
      pg.creator_user_id AS participant_user_id,
      pg.latitude,
      pg.longitude
    FROM public.pickup_games pg
    WHERE pg.status = 'active'
      AND pg.is_visible

    UNION

    SELECT
      pg.id AS pickup_game_id,
      pgr.requester_user_id AS participant_user_id,
      pg.latitude,
      pg.longitude
    FROM public.pickup_game_requests pgr
    JOIN public.pickup_games pg
      ON pg.id = pgr.pickup_game_id
    WHERE pgr.status = 'approved'
      AND pg.status = 'active'
      AND pg.is_visible
  ),
  shared_pickup_games AS (
    SELECT
      other.participant_user_id AS candidate_user_id,
      mine.pickup_game_id,
      CASE
        WHEN NOT p.has_center THEN NULL::double precision
        WHEN mine.latitude IS NULL OR mine.longitude IS NULL THEN NULL::double precision
        ELSE
          3958.7613 * 2 * asin(sqrt(LEAST(1,
            power(sin(radians((mine.latitude - p.center_lat) / 2)), 2)
            + cos(radians(p.center_lat))
            * cos(radians(mine.latitude))
            * power(sin(radians((mine.longitude - p.center_lng) / 2)), 2)
          )))
      END AS distance_miles
    FROM params p
    JOIN viewer_profile vp ON true
    JOIN pickup_participants mine
      ON mine.participant_user_id = vp.id
    JOIN pickup_participants other
      ON other.pickup_game_id = mine.pickup_game_id
     AND other.participant_user_id <> vp.id
    WHERE (
      NOT p.has_center
      OR (
        mine.latitude IS NOT NULL
        AND mine.longitude IS NOT NULL
        AND (
          3958.7613 * 2 * asin(sqrt(LEAST(1,
            power(sin(radians((mine.latitude - p.center_lat) / 2)), 2)
            + cos(radians(p.center_lat))
            * cos(radians(mine.latitude))
            * power(sin(radians((mine.longitude - p.center_lng) / 2)), 2)
          )))
        ) <= p.radius_miles
      )
    )
  ),
  pickup_game_matches AS (
    SELECT
      spg.candidate_user_id,
      'pickup_game'::text AS reason_type,
      'Same pickup game'::text AS reason_label,
      1000
        + LEAST(120, count(DISTINCT spg.pickup_game_id)::int * 35)
        + CASE WHEN min(spg.distance_miles) IS NOT NULL THEN 10 ELSE 0 END AS score
    FROM shared_pickup_games spg
    GROUP BY spg.candidate_user_id
  ),
  shared_venue_events AS (
    SELECT
      other_profile.id AS candidate_user_id,
      mine.venue_event_id,
      CASE
        WHEN NOT p.has_center THEN NULL::double precision
        WHEN v.latitude IS NULL OR v.longitude IS NULL THEN NULL::double precision
        ELSE
          3958.7613 * 2 * asin(sqrt(LEAST(1,
            power(sin(radians((v.latitude - p.center_lat) / 2)), 2)
            + cos(radians(p.center_lat))
            * cos(radians(v.latitude))
            * power(sin(radians((v.longitude - p.center_lng) / 2)), 2)
          )))
      END AS distance_miles
    FROM params p
    JOIN viewer_profile vp ON true
    JOIN public.venue_event_interests mine
      ON lower(trim(coalesce(mine.user_email, ''))) = vp.email_norm
    JOIN public.venue_event_interests other
      ON other.venue_event_id = mine.venue_event_id
     AND lower(trim(coalesce(other.user_email, ''))) <> vp.email_norm
    JOIN public.user_profiles other_profile
      ON lower(trim(coalesce(other_profile.email, ''))) = lower(trim(coalesce(other.user_email, '')))
    LEFT JOIN public.venue_events ve
      ON ve.id = mine.venue_event_id
    LEFT JOIN public.venues v
      ON v.id = ve.venue_id
    WHERE vp.email_norm <> ''
      AND other_profile.id <> vp.id
      AND (
        NOT p.has_center
        OR (
          v.latitude IS NOT NULL
          AND v.longitude IS NOT NULL
          AND (
            3958.7613 * 2 * asin(sqrt(LEAST(1,
              power(sin(radians((v.latitude - p.center_lat) / 2)), 2)
              + cos(radians(p.center_lat))
              * cos(radians(v.latitude))
              * power(sin(radians((v.longitude - p.center_lng) / 2)), 2)
            )))
          ) <= p.radius_miles
        )
      )
  ),
  venue_activity_matches AS (
    SELECT
      sve.candidate_user_id,
      'venue_event'::text AS reason_type,
      'Same watch party'::text AS reason_label,
      800
        + LEAST(90, count(DISTINCT sve.venue_event_id)::int * 20)
        + CASE WHEN min(sve.distance_miles) IS NOT NULL THEN 10 ELSE 0 END AS score
    FROM shared_venue_events sve
    GROUP BY sve.candidate_user_id
  ),
  favorite_team_matches AS (
    SELECT
      other.user_id AS candidate_user_id,
      'favorite_team'::text AS reason_type,
      'Same team'::text AS reason_label,
      600 + LEAST(60, count(DISTINCT other.team_id)::int * 20) AS score
    FROM viewer_profile vp
    JOIN public.user_favorite_teams mine
      ON mine.user_id = vp.id
    JOIN public.user_favorite_teams other
      ON other.team_id = mine.team_id
     AND other.user_id <> vp.id
    GROUP BY other.user_id
  ),
  favorite_venue_matches AS (
    SELECT
      other_profile.id AS candidate_user_id,
      'favorite_venue'::text AS reason_type,
      'Same venue'::text AS reason_label,
      400 + LEAST(50, count(DISTINCT other_fav.venue_id)::int * 15) AS score
    FROM viewer_profile vp
    JOIN public.favorite_venues mine
      ON lower(trim(coalesce(mine.user_email, ''))) = vp.email_norm
    JOIN public.favorite_venues other_fav
      ON other_fav.venue_id = mine.venue_id
     AND lower(trim(coalesce(other_fav.user_email, ''))) <> vp.email_norm
    JOIN public.user_profiles other_profile
      ON lower(trim(coalesce(other_profile.email, ''))) = lower(trim(coalesce(other_fav.user_email, '')))
    WHERE vp.email_norm <> ''
      AND other_profile.id <> vp.id
    GROUP BY other_profile.id
  ),
  mutual_friend_matches AS (
    SELECT
      cand.id AS candidate_user_id,
      'mutual_friends'::text AS reason_type,
      'Mutual friends'::text AS reason_label,
      300 + LEAST(40, count(DISTINCT vf.friend_user_id)::int * 10) AS score
    FROM viewer_profile vp
    JOIN viewer_friends vf ON true
    JOIN public.friendships f
      ON f.status = 'accepted'
     AND COALESCE(f.requester_entity_type, 'user') = 'user'
     AND COALESCE(f.addressee_entity_type, 'user') = 'user'
     AND (
       f.requester_id = vf.friend_user_id
       OR f.addressee_id = vf.friend_user_id
     )
    JOIN public.user_profiles cand
      ON cand.id = CASE
        WHEN f.requester_id = vf.friend_user_id THEN f.addressee_id
        ELSE f.requester_id
      END
     AND cand.id <> vp.id
    GROUP BY cand.id
    HAVING count(DISTINCT vf.friend_user_id) > 0
  ),
  recent_activity_matches AS (
    SELECT
      up.id AS candidate_user_id,
      'recent_activity'::text AS reason_type,
      'Active fan'::text AS reason_label,
      CASE
        WHEN up.updated_at >= now() - interval '7 days' THEN 220
        WHEN up.updated_at >= now() - interval '30 days' THEN 200
        ELSE 0
      END AS score
    FROM public.user_profiles up
    WHERE up.updated_at >= now() - interval '30 days'
      AND COALESCE(up.discoverable_by_fans, true) = true
      AND COALESCE(lower(trim(up.admin_status)), '') = 'active'
      AND up.admin_disabled_at IS NULL
      AND COALESCE(up.is_business_account, false) = false
  ),
  reputation_matches AS (
    SELECT
      up.id AS candidate_user_id,
      'reputation'::text AS reason_type,
      'High reputation'::text AS reason_label,
      100 + LEAST(90, COALESCE(ux.level, 1) * 8 + COALESCE(ux.total_xp, 0) / 250) AS score
    FROM public.user_profiles up
    LEFT JOIN public.user_xp ux
      ON ux.user_id = up.id
    WHERE COALESCE(ux.level, 1) >= 3
       OR COALESCE(ux.total_xp, 0) >= 500
  ),
  candidate_reasons AS (
    SELECT * FROM pickup_game_matches
    UNION ALL
    SELECT * FROM venue_activity_matches
    UNION ALL
    SELECT * FROM favorite_team_matches
    UNION ALL
    SELECT * FROM favorite_venue_matches
    UNION ALL
    SELECT * FROM mutual_friend_matches
    UNION ALL
    SELECT * FROM recent_activity_matches WHERE score > 0
    UNION ALL
    SELECT * FROM reputation_matches
  ),
  candidate_scores AS (
    SELECT
      cr.candidate_user_id,
      sum(cr.score)::int AS total_score
    FROM candidate_reasons cr
    GROUP BY cr.candidate_user_id
  ),
  best_reasons AS (
    SELECT DISTINCT ON (cr.candidate_user_id)
      cr.candidate_user_id,
      cr.reason_type,
      cr.reason_label
    FROM candidate_reasons cr
    ORDER BY cr.candidate_user_id, cr.score DESC, cr.reason_type ASC
  )
  SELECT
    up.id AS user_id,
    up.display_name,
    up.username,
    up.avatar_url,
    up.avatar_thumbnail_url,
    br.reason_type,
    br.reason_label,
    cs.total_score AS score
  FROM params p
  JOIN candidate_scores cs ON true
  JOIN best_reasons br
    ON br.candidate_user_id = cs.candidate_user_id
  JOIN public.user_profiles up
    ON up.id = cs.candidate_user_id
  LEFT JOIN public.user_xp ux
    ON ux.user_id = up.id
  WHERE p.viewer_id IS NOT NULL
    AND up.id <> p.viewer_id
    AND COALESCE(up.discoverable_by_fans, true) = true
    AND COALESCE(lower(trim(up.admin_status)), '') = 'active'
    AND up.admin_disabled_at IS NULL
    AND COALESCE(up.is_business_account, false) = false
    AND NOT EXISTS (
      SELECT 1
      FROM public.blocked_users b
      WHERE (b.blocker_user_id = p.viewer_id AND b.blocked_user_id = up.id)
         OR (b.blocker_user_id = up.id AND b.blocked_user_id = p.viewer_id)
    )
    AND NOT EXISTS (
      SELECT 1
      FROM public.friendships f
      WHERE COALESCE(f.requester_entity_type, 'user') = 'user'
        AND COALESCE(f.addressee_entity_type, 'user') = 'user'
        AND f.status IN ('accepted', 'pending')
        AND (
          (f.requester_id = p.viewer_id AND f.addressee_id = up.id)
          OR (f.requester_id = up.id AND f.addressee_id = p.viewer_id)
        )
    )
    AND NOT EXISTS (
      SELECT 1
      FROM public.suggested_fan_dismissals d
      WHERE d.user_id = p.viewer_id
        AND d.dismissed_user_id = up.id
    )
  ORDER BY
    cs.total_score DESC,
    COALESCE(ux.level, 1) DESC,
    COALESCE(ux.total_xp, 0) DESC,
    up.updated_at DESC NULLS LAST,
    lower(trim(coalesce(up.display_name, up.username, ''))) ASC,
    up.id ASC
  LIMIT (SELECT result_limit FROM params);
$$;

REVOKE ALL ON FUNCTION public.get_profile_friend_suggestions(
  int,
  numeric,
  double precision,
  double precision
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.get_profile_friend_suggestions(
  int,
  numeric,
  double precision,
  double precision
) TO authenticated;

COMMENT ON TABLE public.suggested_fan_dismissals IS
  'Per-user dismissed Suggested Fans cards; excluded from get_profile_friend_suggestions.';

COMMENT ON FUNCTION public.get_profile_friend_suggestions(
  int,
  numeric,
  double precision,
  double precision
) IS
  'Ranked fan suggestions: pickup games, watch parties, teams, venues, mutual friends, activity, reputation. Excludes friends, pending, blocks, business, disabled, undiscoverable, and suggested_fan_dismissals.';
