-- Return all eligible sponsored placements so clients can perform weighted
-- rotation using sponsored_placements.priority_weight.

DROP FUNCTION IF EXISTS public.get_active_sponsored_placement(text, text, text, text, text);

CREATE FUNCTION public.get_active_sponsored_placement(
  p_placement_key text,
  p_country text DEFAULT NULL,
  p_state text DEFAULT NULL,
  p_city text DEFAULT NULL,
  p_sport text DEFAULT NULL
)
RETURNS TABLE (
  id uuid,
  venue_id uuid,
  business_id uuid,
  placement_key text,
  title text,
  subtitle text,
  image_url text,
  cta_label text,
  starts_at timestamptz,
  ends_at timestamptz,
  target_lat double precision,
  target_lng double precision,
  target_radius_miles double precision,
  venue_name text,
  address text,
  city text,
  state text,
  country text,
  phone text,
  primary_sport text,
  latitude double precision,
  longitude double precision,
  cover_photo_url text,
  cover_photo_thumbnail_url text,
  menu_photo_url text,
  menu_photo_thumbnail_url text,
  sport_tags text[],
  fans_going_count integer,
  priority_weight integer
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH normalized AS (
    SELECT
      nullif(lower(btrim(p_placement_key)), '') AS placement_key,
      nullif(lower(btrim(p_country)), '') AS country,
      nullif(lower(btrim(p_state)), '') AS state,
      nullif(lower(btrim(p_city)), '') AS city,
      nullif(lower(btrim(p_sport)), '') AS sport
  ),
  eligible AS (
    SELECT
      sp.*,
      v.venue_name,
      v.address,
      v.city,
      v.state,
      v.country,
      v.phone,
      v.latitude,
      v.longitude,
      v.cover_photo_url,
      v.cover_photo_thumbnail_url,
      v.menu_photo_url,
      v.menu_photo_thumbnail_url,
      v.sport_tags,
      b.admin_status AS business_admin_status,
      (
        CASE WHEN nullif(btrim(coalesce(sp.target_country, '')), '') IS NOT NULL THEN 1 ELSE 0 END +
        CASE WHEN nullif(btrim(coalesce(sp.target_state, '')), '') IS NOT NULL THEN 1 ELSE 0 END +
        CASE WHEN nullif(btrim(coalesce(sp.target_city, '')), '') IS NOT NULL THEN 1 ELSE 0 END +
        CASE WHEN nullif(btrim(coalesce(sp.target_sport, '')), '') IS NOT NULL THEN 1 ELSE 0 END +
        CASE WHEN sp.target_lat IS NOT NULL AND sp.target_lng IS NOT NULL AND sp.target_radius_miles IS NOT NULL THEN 1 ELSE 0 END
      ) AS targeting_score
    FROM public.sponsored_placements sp
    JOIN normalized n ON TRUE
    JOIN public.venues v
      ON v.id = sp.venue_id
    LEFT JOIN public.businesses b
      ON b.id = sp.business_id
    WHERE n.placement_key IS NOT NULL
      AND lower(btrim(sp.placement_key)) = n.placement_key
      AND lower(btrim(coalesce(sp.status, ''))) = 'active'
      AND sp.starts_at <= now()
      AND sp.ends_at >= now()
      AND lower(btrim(coalesce(v.admin_status, 'active'))) = 'active'
      AND (
        sp.business_id IS NULL
        OR b.id IS NULL
        OR lower(btrim(coalesce(b.admin_status, 'active'))) = 'active'
      )
      AND (
        nullif(btrim(coalesce(sp.target_country, '')), '') IS NULL
        OR (n.country IS NOT NULL AND lower(btrim(sp.target_country)) = n.country)
      )
      AND (
        nullif(btrim(coalesce(sp.target_state, '')), '') IS NULL
        OR (n.state IS NOT NULL AND lower(btrim(sp.target_state)) = n.state)
      )
      AND (
        nullif(btrim(coalesce(sp.target_city, '')), '') IS NULL
        OR (n.city IS NOT NULL AND lower(btrim(sp.target_city)) = n.city)
      )
      AND (
        nullif(btrim(coalesce(sp.target_sport, '')), '') IS NULL
        OR (n.sport IS NOT NULL AND lower(btrim(sp.target_sport)) = n.sport)
      )
  )
  SELECT
    e.id,
    e.venue_id,
    e.business_id,
    e.placement_key,
    e.title,
    e.subtitle,
    nullif(btrim(coalesce(e.image_url, '')), '') AS image_url,
    coalesce(nullif(btrim(e.cta_label), ''), 'View Venue') AS cta_label,
    e.starts_at,
    e.ends_at,
    e.target_lat,
    e.target_lng,
    e.target_radius_miles::double precision,
    e.venue_name,
    e.address,
    e.city,
    e.state,
    e.country,
    e.phone,
    coalesce(nullif(e.target_sport, ''), (e.sport_tags)[1], 'Sports') AS primary_sport,
    e.latitude,
    e.longitude,
    e.cover_photo_url,
    e.cover_photo_thumbnail_url,
    e.menu_photo_url,
    e.menu_photo_thumbnail_url,
    e.sport_tags,
    coalesce((
      SELECT count(*)::integer
      FROM public.venue_events ve
      JOIN public.venue_event_interests i
        ON i.venue_event_id = ve.id
      WHERE ve.venue_id = e.venue_id
        AND lower(btrim(coalesce(ve.admin_status, 'active'))) = 'active'
        AND coalesce(i.interest_status, 'going') = 'going'
        AND (
          ve.event_date IS NULL
          OR ve.event_date::date >= (current_date - interval '1 day')::date
        )
    ), 0) AS fans_going_count,
    coalesce(e.priority_weight, 1)::integer AS priority_weight
  FROM eligible e
  ORDER BY
    e.targeting_score DESC,
    e.starts_at DESC,
    e.created_at DESC;
$$;

COMMENT ON FUNCTION public.get_active_sponsored_placement(text, text, text, text, text) IS
  'Read-only active sponsored placement lookup for app surfaces. Returns all eligible rows for client-side weighted rotation using priority_weight.';

REVOKE ALL ON FUNCTION public.get_active_sponsored_placement(text, text, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_active_sponsored_placement(text, text, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_active_sponsored_placement(text, text, text, text, text) TO service_role;
