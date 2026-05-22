-- Self-service business venue release/deletion.
-- Supabase executes each RPC call in one transaction: if any DELETE/UPDATE fails, all database changes roll back.

CREATE TABLE IF NOT EXISTS public.business_venue_deletion_audit (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  action text NOT NULL DEFAULT 'hardDelete',
  venue_id uuid NOT NULL,
  business_id uuid,
  deleted_by uuid,
  deleted_by_email text,
  venue_name text,
  venue_snapshot jsonb NOT NULL,
  deleted_event_ids uuid[] NOT NULL DEFAULT ARRAY[]::uuid[],
  deleted_storage_paths text[] NOT NULL DEFAULT ARRAY[]::text[],
  deleted_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.business_venue_deletion_audit IS
  'Minimal internal audit metadata for business self-service venue release/deletion. No venue/social content is retained here.';

ALTER TABLE public.business_venue_deletion_audit
  ADD COLUMN IF NOT EXISTS action text NOT NULL DEFAULT 'hardDelete';

ALTER TABLE public.business_venue_deletion_audit
  ALTER COLUMN action SET DEFAULT 'hardDelete';

ALTER TABLE public.business_venue_deletion_audit
  DROP CONSTRAINT IF EXISTS business_venue_deletion_audit_action_check;

ALTER TABLE public.business_venue_deletion_audit
  ADD CONSTRAINT business_venue_deletion_audit_action_check
  CHECK (action IN ('delete', 'hardDelete', 'release'));

CREATE INDEX IF NOT EXISTS idx_business_venue_deletion_audit_venue_id
  ON public.business_venue_deletion_audit (venue_id);

CREATE INDEX IF NOT EXISTS idx_business_venue_deletion_audit_deleted_at
  ON public.business_venue_deletion_audit (deleted_at DESC);

ALTER TABLE public.business_venue_deletion_audit ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS business_venue_deletion_audit_no_client_select ON public.business_venue_deletion_audit;
CREATE POLICY business_venue_deletion_audit_no_client_select
  ON public.business_venue_deletion_audit
  FOR SELECT
  TO authenticated
  USING (false);

ALTER TABLE public.venues
  ADD COLUMN IF NOT EXISTS origin_type text NOT NULL DEFAULT 'business';

COMMENT ON COLUMN public.venues.origin_type IS
  'Origin of the public venue row: community rows return to the unclaimed marketplace when released; business rows may be hard-deleted by their owner.';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'venues_origin_type_check'
  ) THEN
    ALTER TABLE public.venues
      ADD CONSTRAINT venues_origin_type_check
      CHECK (origin_type IN ('community', 'business'));
  END IF;
END $$;

-- Community seed rows are unowned/unlinked before claim. Claimed community rows can also be
-- identified when the venue row existed before the approved claim row was created.
UPDATE public.venues
SET origin_type = 'community'
WHERE business_id IS NULL
  AND btrim(coalesce(owner_email, '')) = '';

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'venues'
      AND column_name = 'created_at'
  ) AND EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'venue_claims'
      AND column_name = 'created_at'
  ) THEN
    EXECUTE $sql$
      UPDATE public.venues v
      SET origin_type = 'community'
      WHERE EXISTS (
        SELECT 1
        FROM public.venue_claims vc
        WHERE vc.venue_id::text = v.id::text
          AND lower(btrim(coalesce(vc.approval_status, ''))) = 'approved'
          AND vc.created_at > v.created_at
      )
    $sql$;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.gameon_venue_claim_is_open_pending(p_status text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT NOT (
    lower(trim(COALESCE(p_status, ''))) = 'approved'
    OR lower(trim(COALESCE(p_status, ''))) = 'released'
    OR lower(trim(COALESCE(p_status, ''))) LIKE '%reject%'
  );
$$;

CREATE OR REPLACE FUNCTION public.gameon_storage_path_from_public_url(
  p_public_url text,
  p_bucket text
)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_trimmed text := btrim(coalesce(p_public_url, ''));
  v_marker text := '/storage/v1/object/public/' || p_bucket || '/';
  v_pos integer;
  v_path text;
BEGIN
  IF v_trimmed = '' OR btrim(coalesce(p_bucket, '')) = '' THEN
    RETURN NULL;
  END IF;

  v_pos := strpos(v_trimmed, v_marker);
  IF v_pos <= 0 THEN
    RETURN NULL;
  END IF;

  v_path := substr(v_trimmed, v_pos + char_length(v_marker));
  v_path := split_part(v_path, '?', 1);
  v_path := split_part(v_path, '#', 1);
  v_path := btrim(v_path);

  IF v_path = '' OR length(v_path) > 2048 OR v_path LIKE '/%' OR v_path LIKE '%..%' THEN
    RETURN NULL;
  END IF;

  RETURN v_path;
END;
$$;

CREATE OR REPLACE FUNCTION public.release_or_delete_business_venue(p_venue_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_email text := lower(btrim(coalesce(auth.jwt() ->> 'email', '')));
  v_venue public.venues%ROWTYPE;
  v_event_ids uuid[] := ARRAY[]::uuid[];
  v_event_id_texts text[] := ARRAY[]::text[];
  v_comment_ids uuid[] := ARRAY[]::uuid[];
  v_comment_id_texts text[] := ARRAY[]::text[];
  v_storage_paths text[] := ARRAY[]::text[];
  v_counts jsonb := '{}'::jsonb;
  v_count integer := 0;
  v_is_community boolean := false;
  v_action text := 'hardDelete';
  v_claim_release_count integer := 0;
  v_venue_retained boolean := false;
  v_claim_released boolean := false;
  v_business_fields_cleared boolean := false;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated'
      USING ERRCODE = '28000';
  END IF;

  IF v_email = '' THEN
    SELECT lower(btrim(coalesce(u.email, '')))
      INTO v_email
    FROM auth.users u
    WHERE u.id = v_uid;
  END IF;

  SELECT *
    INTO v_venue
  FROM public.venues
  WHERE id::text = p_venue_id::text
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Venue not found: %', p_venue_id
      USING ERRCODE = 'P0002';
  END IF;

  IF NOT (
    (v_venue.owner_user_id IS NOT NULL AND v_venue.owner_user_id = v_uid)
    OR (
      btrim(coalesce(v_venue.owner_email, '')) <> ''
      AND lower(btrim(v_venue.owner_email)) = v_email
    )
    OR EXISTS (
      SELECT 1
      FROM public.businesses b
      WHERE b.id::text = v_venue.business_id::text
        AND coalesce(lower(btrim(b.admin_status)), 'active') = 'active'
        AND (
          (b.owner_user_id IS NOT NULL AND b.owner_user_id = v_uid)
          OR (
            btrim(coalesce(b.owner_email, '')) <> ''
            AND lower(btrim(b.owner_email)) = v_email
          )
        )
    )
    OR EXISTS (
      SELECT 1
      FROM public.venue_claims vc
      LEFT JOIN public.businesses b ON b.id::text = vc.business_id::text
      WHERE vc.venue_id::text = p_venue_id::text
        AND lower(btrim(coalesce(vc.approval_status, ''))) = 'approved'
        AND (
          (
            btrim(coalesce(vc.owner_email, '')) <> ''
            AND lower(btrim(vc.owner_email)) = v_email
          )
          OR (b.owner_user_id IS NOT NULL AND b.owner_user_id = v_uid)
          OR (
            btrim(coalesce(b.owner_email, '')) <> ''
            AND lower(btrim(b.owner_email)) = v_email
          )
        )
    )
  ) THEN
    RAISE EXCEPTION 'Not authorized to release/delete venue: %', p_venue_id
      USING ERRCODE = '42501';
  END IF;

  v_is_community := lower(btrim(coalesce(v_venue.origin_type, 'business'))) = 'community';
  v_action := CASE WHEN v_is_community THEN 'release' ELSE 'hardDelete' END;

  SELECT coalesce(array_agg(id), ARRAY[]::uuid[])
    INTO v_event_ids
  FROM public.venue_events ve
  WHERE ve.venue_id::text = p_venue_id::text
     OR (
       ve.venue_id IS NULL
       AND btrim(coalesce(v_venue.owner_email, '')) <> ''
       AND lower(btrim(coalesce(ve.owner_email, ''))) = lower(btrim(v_venue.owner_email))
       AND lower(btrim(coalesce(ve.venue_name, ''))) = lower(btrim(coalesce(v_venue.venue_name, '')))
     );
  v_event_id_texts := ARRAY(SELECT unnest(v_event_ids)::text);

  IF cardinality(v_event_ids) > 0 THEN
    SELECT coalesce(array_agg(id), ARRAY[]::uuid[])
      INTO v_comment_ids
    FROM public.venue_event_comments
    WHERE venue_event_id::text = ANY(v_event_id_texts);
    v_comment_id_texts := ARRAY(SELECT unnest(v_comment_ids)::text);
  END IF;

  SELECT coalesce(array_agg(DISTINCT path), ARRAY[]::text[])
    INTO v_storage_paths
  FROM unnest(ARRAY[
    public.gameon_storage_path_from_public_url(v_venue.cover_photo_url, 'venue-photos'),
    public.gameon_storage_path_from_public_url(v_venue.menu_photo_url, 'venue-photos'),
    public.gameon_storage_path_from_public_url(v_venue.cover_photo_thumbnail_url, 'venue-photos'),
    public.gameon_storage_path_from_public_url(v_venue.menu_photo_thumbnail_url, 'venue-photos')
  ]) AS path
  WHERE path IS NOT NULL AND btrim(path) <> '';

  INSERT INTO public.business_venue_deletion_audit (
    action,
    venue_id,
    business_id,
    deleted_by,
    deleted_by_email,
    venue_name,
    venue_snapshot,
    deleted_event_ids,
    deleted_storage_paths
  )
  VALUES (
    v_action,
    p_venue_id,
    v_venue.business_id,
    v_uid,
    NULLIF(v_email, ''),
    v_venue.venue_name,
    jsonb_build_object(
      'venue_id', v_venue.id,
      'business_id', v_venue.business_id,
      'venue_name', v_venue.venue_name,
      'origin_type', v_venue.origin_type,
      'action', v_action,
      'deleted_at', now()
    ),
    v_event_ids,
    v_storage_paths
  );

  IF cardinality(v_comment_ids) > 0 THEN
    DELETE FROM public.venue_event_comment_reactions
    WHERE comment_id::text = ANY(v_comment_id_texts);
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_counts := v_counts || jsonb_build_object('venue_event_comment_reactions', v_count);

    DELETE FROM public.venue_event_comment_likes
    WHERE comment_id::text = ANY(v_comment_id_texts);
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_counts := v_counts || jsonb_build_object('venue_event_comment_likes', v_count);

    DELETE FROM public.comment_reports
    WHERE comment_id::text = ANY(v_comment_id_texts);
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_counts := v_counts || jsonb_build_object('comment_reports_by_comment', v_count);
  ELSE
    v_counts := v_counts || jsonb_build_object(
      'venue_event_comment_reactions', 0,
      'venue_event_comment_likes', 0,
      'comment_reports_by_comment', 0
    );
  END IF;

  IF cardinality(v_event_ids) > 0 THEN
    DELETE FROM public.comment_reports
    WHERE venue_event_id::text = ANY(v_event_id_texts);
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_counts := v_counts || jsonb_build_object('comment_reports_by_event', v_count);

    DELETE FROM public.venue_event_predictions
    WHERE venue_event_id::text = ANY(v_event_id_texts);
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_counts := v_counts || jsonb_build_object('venue_event_predictions', v_count);

    DELETE FROM public.venue_event_comments
    WHERE venue_event_id::text = ANY(v_event_id_texts);
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_counts := v_counts || jsonb_build_object('venue_event_comments', v_count);

    DELETE FROM public.venue_event_vibes
    WHERE venue_event_id::text = ANY(v_event_id_texts);
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_counts := v_counts || jsonb_build_object('venue_event_vibes', v_count);

    DELETE FROM public.venue_event_interests
    WHERE venue_event_id::text = ANY(v_event_id_texts);
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_counts := v_counts || jsonb_build_object('venue_event_interests', v_count);

    DELETE FROM public.business_game_history
    WHERE venue_id::text = p_venue_id::text
       OR original_venue_event_id::text = ANY(v_event_id_texts);
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_counts := v_counts || jsonb_build_object('business_game_history', v_count);

    DELETE FROM public.venue_events
    WHERE id::text = ANY(v_event_id_texts);
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_counts := v_counts || jsonb_build_object('venue_events', v_count);
  ELSE
    v_counts := v_counts || jsonb_build_object(
      'comment_reports_by_event', 0,
      'venue_event_predictions', 0,
      'venue_event_comments', 0,
      'venue_event_vibes', 0,
      'venue_event_interests', 0,
      'business_game_history', 0,
      'venue_events', 0
    );

    DELETE FROM public.business_game_history
    WHERE venue_id::text = p_venue_id::text;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_counts := jsonb_set(v_counts, '{business_game_history}', to_jsonb(v_count), true);
  END IF;

  IF v_is_community THEN
    UPDATE public.venue_claims
    SET venue_id = NULL,
        business_id = NULL,
        approval_status = 'released'
    WHERE venue_id::text = p_venue_id::text
      AND lower(btrim(coalesce(approval_status, ''))) = 'approved';
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_claim_release_count := v_count;
    v_counts := v_counts || jsonb_build_object('venue_claims_released', v_count);

    UPDATE public.venues
    SET business_id = NULL,
        owner_user_id = NULL,
        owner_email = NULL,
        phone = '',
        website = '',
        description = '',
        features = '',
        screen_count = NULL,
        serves_food = NULL,
        has_wifi = NULL,
        has_garden = NULL,
        has_projector = NULL,
        pet_friendly = NULL,
        supporter_country = NULL,
        cover_photo_url = '',
        menu_photo_url = '',
        cover_photo_thumbnail_url = NULL,
        menu_photo_thumbnail_url = NULL,
        admin_status = 'active',
        origin_type = 'community'
    WHERE id::text = p_venue_id::text;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_counts := v_counts || jsonb_build_object('venues_released', v_count);

    SELECT EXISTS (
      SELECT 1
      FROM public.venues v
      WHERE v.id::text = p_venue_id::text
        AND lower(btrim(coalesce(v.origin_type, ''))) = 'community'
        AND lower(btrim(coalesce(v.admin_status, 'active'))) = 'active'
    )
    INTO v_venue_retained;

    SELECT (
      v_claim_release_count > 0
      AND NOT EXISTS (
        SELECT 1
        FROM public.venue_claims vc
        WHERE vc.venue_id::text = p_venue_id::text
          AND lower(btrim(coalesce(vc.approval_status, ''))) = 'approved'
      )
    )
    INTO v_claim_released;

    SELECT EXISTS (
      SELECT 1
      FROM public.venues v
      WHERE v.id::text = p_venue_id::text
        AND v.business_id IS NULL
        AND v.owner_user_id IS NULL
        AND v.owner_email IS NULL
        AND btrim(coalesce(v.phone, '')) = ''
        AND btrim(coalesce(v.website, '')) = ''
        AND btrim(coalesce(v.description, '')) = ''
        AND btrim(coalesce(v.features, '')) = ''
        AND btrim(coalesce(v.cover_photo_url, '')) = ''
        AND btrim(coalesce(v.menu_photo_url, '')) = ''
        AND btrim(coalesce(v.cover_photo_thumbnail_url, '')) = ''
        AND btrim(coalesce(v.menu_photo_thumbnail_url, '')) = ''
    )
    INTO v_business_fields_cleared;

    IF NOT (v_venue_retained AND v_claim_released AND v_business_fields_cleared) THEN
      RAISE EXCEPTION 'Community venue release verification failed for venue: %', p_venue_id
        USING ERRCODE = 'P0001';
    END IF;
  ELSE
    DELETE FROM public.favorite_venues
    WHERE venue_id::text = p_venue_id::text;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_counts := v_counts || jsonb_build_object('favorite_venues', v_count);

    UPDATE public.user_profiles
    SET home_crowd_venue_id = NULL,
        home_crowd_set_at = NULL
    WHERE home_crowd_venue_id::text = p_venue_id::text;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_counts := v_counts || jsonb_build_object('home_crowd_profiles_unlinked', v_count);

    DELETE FROM public.venue_reports
    WHERE venue_id::text = p_venue_id::text;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_counts := v_counts || jsonb_build_object('venue_reports', v_count);

    UPDATE public.venue_claims
    SET venue_id = NULL,
        business_id = NULL
    WHERE venue_id::text = p_venue_id::text;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_counts := v_counts || jsonb_build_object('venue_claims_unlinked', v_count);

    DELETE FROM public.venues
    WHERE id::text = p_venue_id::text;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_counts := v_counts || jsonb_build_object('venues', v_count);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'action', v_action,
    'venue_retained', CASE WHEN v_is_community THEN v_venue_retained ELSE false END,
    'claim_released', CASE WHEN v_is_community THEN v_claim_released ELSE NULL END,
    'business_fields_cleared', CASE WHEN v_is_community THEN v_business_fields_cleared ELSE NULL END,
    'storage_paths_returned', cardinality(v_storage_paths),
    'venue_id', p_venue_id,
    'business_id', v_venue.business_id,
    'deleted_event_ids', v_event_ids,
    'deleted_storage_paths', v_storage_paths,
    'deleted_counts', v_counts
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.delete_business_venue_cascade(p_venue_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN public.release_or_delete_business_venue(p_venue_id);
END;
$$;

REVOKE ALL ON FUNCTION public.gameon_storage_path_from_public_url(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.release_or_delete_business_venue(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.delete_business_venue_cascade(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.release_or_delete_business_venue(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_business_venue_cascade(uuid) TO authenticated;

COMMENT ON FUNCTION public.release_or_delete_business_venue(uuid) IS
  'Releases claimed community venues back to the unclaimed marketplace, or hard-deletes business-created venues. Does not delete the business account.';

COMMENT ON FUNCTION public.delete_business_venue_cascade(uuid) IS
  'Compatibility wrapper for release_or_delete_business_venue(uuid).';
