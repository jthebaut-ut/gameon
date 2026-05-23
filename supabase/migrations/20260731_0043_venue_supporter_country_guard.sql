-- Guarded venue supporter identity updates for business-owner watch-spot banners.
-- Keeps Discover rendering safe by constraining stored values to a small canonical allowlist.

ALTER TABLE public.venues
  ADD COLUMN IF NOT EXISTS supporter_country text NULL;

CREATE OR REPLACE FUNCTION public.normalize_venue_supporter_country(p_country text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_key text := lower(regexp_replace(btrim(coalesce(p_country, '')), '\s+', ' ', 'g'));
BEGIN
  IF v_key = '' THEN
    RETURN NULL;
  END IF;

  CASE v_key
    WHEN 'brazil', 'brasil' THEN RETURN 'Brazil';
    WHEN 'usa', 'us', 'u.s.', 'u.s.a.', 'united states', 'united states of america' THEN RETURN 'USA';
    WHEN 'mexico', 'méxico' THEN RETURN 'Mexico';
    WHEN 'canada' THEN RETURN 'Canada';
    WHEN 'costa rica' THEN RETURN 'Costa Rica';
    WHEN 'bolivia' THEN RETURN 'Bolivia';
    WHEN 'france' THEN RETURN 'France';
    WHEN 'belgium', 'belgique', 'belgie' THEN RETURN 'Belgium';
    WHEN 'argentina' THEN RETURN 'Argentina';
    WHEN 'england' THEN RETURN 'England';
    WHEN 'spain', 'espana', 'españa' THEN RETURN 'Spain';
    WHEN 'germany', 'deutschland' THEN RETURN 'Germany';
    WHEN 'italy', 'italia' THEN RETURN 'Italy';
    WHEN 'portugal' THEN RETURN 'Portugal';
    WHEN 'netherlands', 'the netherlands', 'holland' THEN RETURN 'Netherlands';
    WHEN 'colombia' THEN RETURN 'Colombia';
    WHEN 'uruguay' THEN RETURN 'Uruguay';
    WHEN 'chile' THEN RETURN 'Chile';
    WHEN 'japan' THEN RETURN 'Japan';
    WHEN 'south korea', 'korea republic', 'republic of korea', 'korea, republic of' THEN RETURN 'South Korea';
    WHEN 'australia' THEN RETURN 'Australia';
    ELSE
      RAISE EXCEPTION 'invalid_venue_supporter_country: %', p_country
        USING ERRCODE = '22023';
  END CASE;
END;
$$;

UPDATE public.venues
SET supporter_country = CASE lower(regexp_replace(btrim(coalesce(supporter_country, '')), '\s+', ' ', 'g'))
  WHEN '' THEN NULL
  WHEN 'brazil' THEN 'Brazil'
  WHEN 'brasil' THEN 'Brazil'
  WHEN 'usa' THEN 'USA'
  WHEN 'us' THEN 'USA'
  WHEN 'u.s.' THEN 'USA'
  WHEN 'u.s.a.' THEN 'USA'
  WHEN 'united states' THEN 'USA'
  WHEN 'united states of america' THEN 'USA'
  WHEN 'mexico' THEN 'Mexico'
  WHEN 'méxico' THEN 'Mexico'
  WHEN 'canada' THEN 'Canada'
  WHEN 'costa rica' THEN 'Costa Rica'
  WHEN 'bolivia' THEN 'Bolivia'
  WHEN 'france' THEN 'France'
  WHEN 'belgium' THEN 'Belgium'
  WHEN 'belgique' THEN 'Belgium'
  WHEN 'belgie' THEN 'Belgium'
  WHEN 'argentina' THEN 'Argentina'
  WHEN 'england' THEN 'England'
  WHEN 'spain' THEN 'Spain'
  WHEN 'espana' THEN 'Spain'
  WHEN 'españa' THEN 'Spain'
  WHEN 'germany' THEN 'Germany'
  WHEN 'deutschland' THEN 'Germany'
  WHEN 'italy' THEN 'Italy'
  WHEN 'italia' THEN 'Italy'
  WHEN 'portugal' THEN 'Portugal'
  WHEN 'netherlands' THEN 'Netherlands'
  WHEN 'the netherlands' THEN 'Netherlands'
  WHEN 'holland' THEN 'Netherlands'
  WHEN 'colombia' THEN 'Colombia'
  WHEN 'uruguay' THEN 'Uruguay'
  WHEN 'chile' THEN 'Chile'
  WHEN 'japan' THEN 'Japan'
  WHEN 'south korea' THEN 'South Korea'
  WHEN 'korea republic' THEN 'South Korea'
  WHEN 'republic of korea' THEN 'South Korea'
  WHEN 'korea, republic of' THEN 'South Korea'
  WHEN 'australia' THEN 'Australia'
  ELSE NULL
END
WHERE supporter_country IS NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'venues_supporter_country_allowed_check'
      AND conrelid = 'public.venues'::regclass
  ) THEN
    ALTER TABLE public.venues
      ADD CONSTRAINT venues_supporter_country_allowed_check
      CHECK (
        supporter_country IS NULL
        OR supporter_country IN (
          'Brazil',
          'USA',
          'Mexico',
          'Canada',
          'Costa Rica',
          'Bolivia',
          'France',
          'Belgium',
          'Argentina',
          'England',
          'Spain',
          'Germany',
          'Italy',
          'Portugal',
          'Netherlands',
          'Colombia',
          'Uruguay',
          'Chile',
          'Japan',
          'South Korea',
          'Australia'
        )
      );
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.enforce_venue_supporter_country_update()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_email text := lower(btrim(coalesce(auth.jwt() ->> 'email', '')));
  v_allowed boolean := false;
BEGIN
  NEW.supporter_country := public.normalize_venue_supporter_country(NEW.supporter_country);

  IF auth.role() = 'service_role' THEN
    v_allowed := true;
  ELSIF v_uid IS NOT NULL THEN
    v_allowed :=
      (
        coalesce(lower(btrim(OLD.admin_status)), 'active') = 'active'
        AND (
          OLD.owner_user_id = v_uid
          OR (
            v_email <> ''
            AND lower(btrim(coalesce(OLD.owner_email, ''))) = v_email
          )
        )
      )
      OR EXISTS (
        SELECT 1
        FROM public.businesses b
        WHERE b.id = OLD.business_id
          AND coalesce(lower(btrim(b.admin_status)), 'active') = 'active'
          AND (
            b.owner_user_id = v_uid
            OR (
              v_email <> ''
              AND lower(btrim(coalesce(b.owner_email, ''))) = v_email
            )
          )
      );
  END IF;

  IF NOT v_allowed THEN
    RAISE EXCEPTION 'venue_supporter_country_update_forbidden'
      USING ERRCODE = '42501';
  END IF;

  IF NEW.supporter_country IS NOT DISTINCT FROM OLD.supporter_country THEN
    RETURN NEW;
  END IF;

  IF to_regclass('public.admin_audit_logs') IS NOT NULL THEN
    INSERT INTO public.admin_audit_logs (
      admin_email,
      action,
      target_type,
      target_id,
      before_data,
      after_data,
      reason
    )
    VALUES (
      coalesce(nullif(v_email, ''), v_uid::text, auth.role(), 'unknown'),
      'update_venue_supporter_country',
      'venue',
      OLD.id::text,
      jsonb_build_object(
        'supporter_country', OLD.supporter_country,
        'actor_user_id', v_uid,
        'actor_email', nullif(v_email, '')
      ),
      jsonb_build_object(
        'supporter_country', NEW.supporter_country,
        'actor_user_id', v_uid,
        'actor_email', nullif(v_email, '')
      ),
      'owner_tools'
    );
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS venues_supporter_country_guard
  ON public.venues;

CREATE TRIGGER venues_supporter_country_guard
  BEFORE UPDATE OF supporter_country ON public.venues
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_venue_supporter_country_update();

CREATE OR REPLACE FUNCTION public.update_venue_supporter_country(
  p_venue_id uuid,
  p_supporter_country text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_before text;
  v_after text;
  v_updated public.venues%ROWTYPE;
BEGIN
  IF p_venue_id IS NULL THEN
    RAISE EXCEPTION 'venue_id_required'
      USING ERRCODE = '22023';
  END IF;

  SELECT supporter_country
  INTO v_before
  FROM public.venues
  WHERE id = p_venue_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'venue_not_found'
      USING ERRCODE = 'P0002';
  END IF;

  v_after := public.normalize_venue_supporter_country(p_supporter_country);

  UPDATE public.venues
  SET supporter_country = v_after
  WHERE id = p_venue_id
  RETURNING *
  INTO v_updated;

  RETURN jsonb_build_object(
    'ok', true,
    'venue_id', v_updated.id,
    'before_supporter_country', v_before,
    'supporter_country', v_updated.supporter_country
  );
END;
$$;

REVOKE ALL ON FUNCTION public.update_venue_supporter_country(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_venue_supporter_country(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_venue_supporter_country(uuid, text) TO service_role;

COMMENT ON FUNCTION public.update_venue_supporter_country(uuid, text) IS
  'Guarded owner/admin path for updating venues.supporter_country. Normalizes empty input to NULL and rejects values outside the public watch-spot allowlist.';
