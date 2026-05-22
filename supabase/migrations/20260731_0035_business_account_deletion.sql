-- Self-service business account deletion preview + cascade cleanup.
-- Database cleanup is transactional. Storage files are returned as exact paths for
-- Supabase Storage API deletion after this RPC commits.

CREATE TABLE IF NOT EXISTS public.business_account_deletion_audit (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  action text NOT NULL DEFAULT 'businessAccountDelete',
  business_id uuid NOT NULL,
  deleted_by uuid,
  deleted_by_email text,
  business_snapshot jsonb NOT NULL,
  released_venue_ids uuid[] NOT NULL DEFAULT ARRAY[]::uuid[],
  hard_deleted_venue_ids uuid[] NOT NULL DEFAULT ARRAY[]::uuid[],
  deleted_event_ids uuid[] NOT NULL DEFAULT ARRAY[]::uuid[],
  deleted_storage_paths text[] NOT NULL DEFAULT ARRAY[]::text[],
  deleted_counts jsonb NOT NULL DEFAULT '{}'::jsonb,
  deleted_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.business_account_deletion_audit IS
  'Minimal internal audit metadata for business account deletion. No venue/social content is retained.';

ALTER TABLE public.business_account_deletion_audit ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS business_account_deletion_audit_no_client_select ON public.business_account_deletion_audit;
CREATE POLICY business_account_deletion_audit_no_client_select
  ON public.business_account_deletion_audit
  FOR SELECT
  TO authenticated
  USING (false);

CREATE INDEX IF NOT EXISTS idx_business_account_deletion_audit_business_id
  ON public.business_account_deletion_audit (business_id);

CREATE INDEX IF NOT EXISTS idx_business_account_deletion_audit_deleted_at
  ON public.business_account_deletion_audit (deleted_at DESC);

CREATE OR REPLACE FUNCTION public.gameon_venue_claim_is_open_pending(p_status text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT NOT (
    lower(trim(COALESCE(p_status, ''))) = 'approved'
    OR lower(trim(COALESCE(p_status, ''))) = 'released'
    OR lower(trim(COALESCE(p_status, ''))) = 'business_deleted'
    OR lower(trim(COALESCE(p_status, ''))) = 'cancelled'
    OR lower(trim(COALESCE(p_status, ''))) LIKE '%reject%'
  );
$$;

CREATE OR REPLACE FUNCTION public.business_account_deletion_preview(p_business_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_email text := lower(btrim(coalesce(auth.jwt() ->> 'email', '')));
  v_business public.businesses%ROWTYPE;
  v_owner_email text;
  v_preview jsonb;
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
    INTO v_business
  FROM public.businesses
  WHERE id::text = p_business_id::text;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Business not found: %', p_business_id
      USING ERRCODE = 'P0002';
  END IF;

  v_owner_email := lower(btrim(coalesce(v_business.owner_email, '')));

  IF NOT (
    (v_business.owner_user_id IS NOT NULL AND v_business.owner_user_id = v_uid)
    OR (v_owner_email <> '' AND v_owner_email = v_email)
  ) THEN
    RAISE EXCEPTION 'Not authorized to preview business deletion: %', p_business_id
      USING ERRCODE = '42501';
  END IF;

  WITH claim_scope AS (
    SELECT DISTINCT vc.*
    FROM public.venue_claims vc
    WHERE vc.business_id::text = p_business_id::text
       OR (
         v_owner_email <> ''
         AND lower(btrim(coalesce(vc.owner_email, ''))) = v_owner_email
       )
  ),
  pending_claims AS (
    SELECT *
    FROM claim_scope
    WHERE lower(btrim(coalesce(approval_status, ''))) NOT IN ('approved', 'released', 'business_deleted', 'cancelled')
  ),
  pending_claim_venues AS (
    SELECT pc.id AS claim_id, pc.venue_name AS claim_venue_name, pc.approval_status, v.*
    FROM pending_claims pc
    LEFT JOIN public.venues v ON v.id::text = pc.venue_id::text
  ),
  pending_business_claims AS (
    SELECT pc.*
    FROM pending_claims pc
    LEFT JOIN public.venues v ON v.id::text = pc.venue_id::text
    WHERE coalesce(lower(btrim(v.origin_type)), 'business') <> 'community'
  ),
  target_venue_ids AS (
    SELECT DISTINCT v.id
    FROM public.venues v
    WHERE v.business_id::text = p_business_id::text
       OR (
         v.business_id IS NULL
         AND v_business.owner_user_id IS NOT NULL
         AND v.owner_user_id = v_business.owner_user_id
       )
       OR (
         v.business_id IS NULL
         AND v_owner_email <> ''
         AND lower(btrim(coalesce(v.owner_email, ''))) = v_owner_email
       )
       OR EXISTS (
         SELECT 1
         FROM claim_scope vc
         WHERE vc.venue_id::text = v.id::text
           AND lower(btrim(coalesce(vc.approval_status, ''))) = 'approved'
       )
       OR v.id::text IN (
         SELECT pc.venue_id::text
         FROM pending_business_claims pc
         WHERE pc.venue_id IS NOT NULL
       )
  ),
  target_venues AS (
    SELECT v.*
    FROM public.venues v
    JOIN target_venue_ids ids ON ids.id::text = v.id::text
  ),
  target_events AS (
    SELECT DISTINCT ve.id
    FROM public.venue_events ve
    WHERE EXISTS (
      SELECT 1
      FROM target_venues tv
      WHERE ve.venue_id::text = tv.id::text
         OR (
           ve.venue_id IS NULL
           AND btrim(coalesce(tv.owner_email, '')) <> ''
           AND lower(btrim(coalesce(ve.owner_email, ''))) = lower(btrim(tv.owner_email))
           AND lower(btrim(coalesce(ve.venue_name, ''))) = lower(btrim(coalesce(tv.venue_name, '')))
         )
    )
  ),
  event_details AS (
    SELECT DISTINCT
      ve.id,
      coalesce(nullif(btrim(tv.venue_name), ''), nullif(btrim(ve.venue_name), ''), 'Unknown venue') AS venue_name,
      ve.event_title,
      ve.sport,
      ve.external_league,
      ve.event_date,
      ve.event_time,
      ve.scheduled_start_at,
      ve.admin_status
    FROM public.venue_events ve
    JOIN target_events te ON te.id::text = ve.id::text
    LEFT JOIN target_venues tv
      ON tv.id::text = ve.venue_id::text
      OR (
        ve.venue_id IS NULL
        AND btrim(coalesce(tv.owner_email, '')) <> ''
        AND lower(btrim(coalesce(ve.owner_email, ''))) = lower(btrim(tv.owner_email))
        AND lower(btrim(coalesce(ve.venue_name, ''))) = lower(btrim(coalesce(tv.venue_name, '')))
      )
  ),
  storage_paths AS (
    SELECT DISTINCT storage.path
    FROM target_venues tv
    CROSS JOIN LATERAL unnest(ARRAY[
      public.gameon_storage_path_from_public_url(tv.cover_photo_url, 'venue-photos'),
      public.gameon_storage_path_from_public_url(tv.menu_photo_url, 'venue-photos'),
      public.gameon_storage_path_from_public_url(tv.cover_photo_thumbnail_url, 'venue-photos'),
      public.gameon_storage_path_from_public_url(tv.menu_photo_thumbnail_url, 'venue-photos')
    ]) AS storage(path)
    WHERE storage.path IS NOT NULL
      AND btrim(storage.path) <> ''
  )
  SELECT jsonb_build_object(
    'ok', true,
    'business_id', v_business.id,
    'business_name', v_business.display_name,
    'business_venues_to_delete', coalesce((
      SELECT jsonb_agg(
        jsonb_build_object(
          'id', tv.id,
          'venue_name', tv.venue_name,
          'origin_type', coalesce(nullif(btrim(tv.origin_type), ''), 'business'),
          'label', 'Will be deleted'
        )
        ORDER BY lower(coalesce(tv.venue_name, ''))
      )
      FROM target_venues tv
      WHERE lower(btrim(coalesce(tv.origin_type, 'business'))) <> 'community'
        AND lower(btrim(coalesce(tv.admin_status, 'active'))) IN ('', 'active')
    ), '[]'::jsonb),
    'community_venues_to_release', coalesce((
      SELECT jsonb_agg(
        jsonb_build_object(
          'id', tv.id,
          'venue_name', tv.venue_name,
          'origin_type', 'community',
          'label', 'Will be returned to FanGeo community'
        )
        ORDER BY lower(coalesce(tv.venue_name, ''))
      )
      FROM target_venues tv
      WHERE lower(btrim(coalesce(tv.origin_type, 'business'))) = 'community'
    ), '[]'::jsonb),
    'pending_business_venues_to_delete', coalesce((
      SELECT jsonb_agg(item ORDER BY lower(coalesce(item ->> 'venue_name', '')))
      FROM (
        SELECT DISTINCT jsonb_build_object(
          'id', pcv.claim_id,
          'venue_id', pcv.id,
          'venue_name', coalesce(nullif(btrim(pcv.venue_name), ''), nullif(btrim(pcv.claim_venue_name), ''), 'Pending venue'),
          'origin_type', coalesce(nullif(btrim(pcv.origin_type), ''), 'business'),
          'approval_status', pcv.approval_status,
          'label', 'Pending business venue to delete'
        ) AS item
        FROM pending_claim_venues pcv
        WHERE coalesce(lower(btrim(pcv.origin_type)), 'business') <> 'community'
          AND pcv.id IS NULL
        UNION
        SELECT DISTINCT jsonb_build_object(
          'id', tv.id,
          'venue_id', tv.id,
          'venue_name', coalesce(nullif(btrim(tv.venue_name), ''), 'Pending venue'),
          'origin_type', coalesce(nullif(btrim(tv.origin_type), ''), 'business'),
          'approval_status', tv.admin_status,
          'label', 'Pending business venue to delete'
        ) AS item
        FROM target_venues tv
        WHERE lower(btrim(coalesce(tv.origin_type, 'business'))) <> 'community'
          AND lower(btrim(coalesce(tv.admin_status, 'active'))) NOT IN ('', 'active')
      ) pending_business_items
    ), '[]'::jsonb),
    'pending_community_claims_to_cancel', coalesce((
      SELECT jsonb_agg(
        jsonb_build_object(
          'id', pc.claim_id,
          'venue_id', pc.id,
          'venue_name', coalesce(nullif(btrim(pc.venue_name), ''), nullif(btrim(pc.claim_venue_name), ''), 'Community venue claim'),
          'origin_type', 'community',
          'approval_status', pc.approval_status,
          'label', 'Pending community claim to cancel'
        )
        ORDER BY lower(coalesce(pc.venue_name, pc.claim_venue_name, ''))
      )
      FROM pending_claim_venues pc
      WHERE lower(btrim(coalesce(pc.origin_type, ''))) = 'community'
    ), '[]'::jsonb),
    'business_venue_count', (
      SELECT count(*)
      FROM target_venues tv
      WHERE lower(btrim(coalesce(tv.origin_type, 'business'))) <> 'community'
    ),
    'community_venue_count', (
      SELECT count(*)
      FROM target_venues tv
      WHERE lower(btrim(coalesce(tv.origin_type, 'business'))) = 'community'
    ),
    'event_count', (SELECT count(*) FROM target_events),
    'games_events_to_remove', coalesce((
      SELECT jsonb_agg(
        jsonb_build_object(
          'id', ed.id,
          'venue_name', ed.venue_name,
          'event_title', ed.event_title,
          'sport', ed.sport,
          'league', ed.external_league,
          'event_date', ed.event_date,
          'event_time', ed.event_time,
          'scheduled_start_at', ed.scheduled_start_at,
          'status', ed.admin_status
        )
        ORDER BY lower(coalesce(ed.venue_name, '')), ed.scheduled_start_at NULLS LAST, ed.event_date NULLS LAST, ed.event_time NULLS LAST, lower(coalesce(ed.event_title, ''))
      )
      FROM event_details ed
    ), '[]'::jsonb),
    'photo_count', (SELECT count(*) FROM storage_paths),
    'pending_claim_count', (SELECT count(*) FROM pending_claims)
  )
  INTO v_preview;

  RETURN v_preview;
END;
$$;

CREATE OR REPLACE FUNCTION public.delete_business_account_cascade(p_business_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_email text := lower(btrim(coalesce(auth.jwt() ->> 'email', '')));
  v_business public.businesses%ROWTYPE;
  v_owner_email text;
  v_owner_user_id_text text := '';
  v_claim_scope_ids uuid[] := ARRAY[]::uuid[];
  v_claim_scope_id_texts text[] := ARRAY[]::text[];
  v_target_venue_ids uuid[] := ARRAY[]::uuid[];
  v_target_venue_id_texts text[] := ARRAY[]::text[];
  v_business_venue_ids uuid[] := ARRAY[]::uuid[];
  v_business_venue_id_texts text[] := ARRAY[]::text[];
  v_community_venue_ids uuid[] := ARRAY[]::uuid[];
  v_community_venue_id_texts text[] := ARRAY[]::text[];
  v_pending_claim_ids uuid[] := ARRAY[]::uuid[];
  v_pending_claim_id_texts text[] := ARRAY[]::text[];
  v_pending_community_claim_ids uuid[] := ARRAY[]::uuid[];
  v_pending_community_claim_id_texts text[] := ARRAY[]::text[];
  v_pending_business_claim_ids uuid[] := ARRAY[]::uuid[];
  v_pending_business_claim_id_texts text[] := ARRAY[]::text[];
  v_event_ids uuid[] := ARRAY[]::uuid[];
  v_event_id_texts text[] := ARRAY[]::text[];
  v_comment_ids uuid[] := ARRAY[]::uuid[];
  v_comment_id_texts text[] := ARRAY[]::text[];
  v_storage_paths text[] := ARRAY[]::text[];
  v_counts jsonb := '{}'::jsonb;
  v_count integer := 0;
  v_conflicting_venue_id uuid;
  v_conflicting_business_id uuid;
  v_conflicting_owner_email text;
  v_active_claims_remaining integer := 0;
  v_released_claims integer := 0;
  v_cancelled_claims integer := 0;
  v_business_deleted_claims integer := 0;
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
    INTO v_business
  FROM public.businesses
  WHERE id::text = p_business_id::text
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Business not found: %', p_business_id
      USING ERRCODE = 'P0002';
  END IF;

  v_owner_email := lower(btrim(coalesce(v_business.owner_email, '')));
  v_owner_user_id_text := coalesce(v_business.owner_user_id::text, '');

  IF NOT (
    (v_business.owner_user_id IS NOT NULL AND v_business.owner_user_id = v_uid)
    OR (v_owner_email <> '' AND v_owner_email = v_email)
  ) THEN
    RAISE EXCEPTION 'Not authorized to delete business account: %', p_business_id
      USING ERRCODE = '42501';
  END IF;

  SELECT coalesce(array_agg(DISTINCT vc.id), ARRAY[]::uuid[])
    INTO v_claim_scope_ids
  FROM public.venue_claims vc
  WHERE vc.business_id::text = p_business_id::text
     OR (
       v_owner_email <> ''
       AND lower(btrim(coalesce(vc.owner_email, ''))) = v_owner_email
     )
     OR (
       v_owner_user_id_text <> ''
       AND EXISTS (
         SELECT 1
         FROM public.venues v
         WHERE v.id::text = vc.venue_id::text
           AND v.owner_user_id::text = v_owner_user_id_text
       )
     );
  v_claim_scope_id_texts := ARRAY(SELECT unnest(v_claim_scope_ids)::text);

  SELECT coalesce(array_agg(DISTINCT id), ARRAY[]::uuid[])
    INTO v_pending_claim_ids
  FROM public.venue_claims vc
  WHERE vc.id::text = ANY(v_claim_scope_id_texts)
    AND lower(btrim(coalesce(vc.approval_status, ''))) NOT IN ('approved', 'released', 'business_deleted', 'cancelled');
  v_pending_claim_id_texts := ARRAY(SELECT unnest(v_pending_claim_ids)::text);

  SELECT coalesce(array_agg(DISTINCT vc.id), ARRAY[]::uuid[])
    INTO v_pending_community_claim_ids
  FROM public.venue_claims vc
  JOIN public.venues v ON v.id::text = vc.venue_id::text
  WHERE vc.id::text = ANY(v_pending_claim_id_texts)
    AND lower(btrim(coalesce(v.origin_type, ''))) = 'community';
  v_pending_community_claim_id_texts := ARRAY(SELECT unnest(v_pending_community_claim_ids)::text);

  SELECT coalesce(array_agg(DISTINCT vc.id), ARRAY[]::uuid[])
    INTO v_pending_business_claim_ids
  FROM public.venue_claims vc
  LEFT JOIN public.venues v ON v.id::text = vc.venue_id::text
  WHERE vc.id::text = ANY(v_pending_claim_id_texts)
    AND coalesce(lower(btrim(v.origin_type)), 'business') <> 'community';
  v_pending_business_claim_id_texts := ARRAY(SELECT unnest(v_pending_business_claim_ids)::text);

  SELECT coalesce(array_agg(DISTINCT target_id), ARRAY[]::uuid[])
    INTO v_target_venue_ids
  FROM (
    SELECT v.id AS target_id
    FROM public.venues v
    WHERE v.business_id::text = p_business_id::text
       OR (
         v.business_id IS NULL
         AND v_business.owner_user_id IS NOT NULL
         AND v.owner_user_id = v_business.owner_user_id
       )
       OR (
         v.business_id IS NULL
         AND v_owner_email <> ''
         AND lower(btrim(coalesce(v.owner_email, ''))) = v_owner_email
       )
       OR EXISTS (
         SELECT 1
         FROM public.venue_claims vc
         WHERE vc.venue_id::text = v.id::text
           AND lower(btrim(coalesce(vc.approval_status, ''))) = 'approved'
           AND (
             vc.business_id::text = p_business_id::text
             OR (
               vc.business_id IS NULL
               AND v_owner_email <> ''
               AND lower(btrim(coalesce(vc.owner_email, ''))) = v_owner_email
             )
           )
       )
       OR v.id::text IN (
         SELECT vc.venue_id::text
         FROM public.venue_claims vc
         WHERE vc.id::text = ANY(v_pending_business_claim_id_texts)
           AND vc.venue_id IS NOT NULL
       )
  ) targets;

  v_target_venue_id_texts := ARRAY(SELECT unnest(v_target_venue_ids)::text);

  PERFORM 1
  FROM public.venues v
  WHERE v.id::text = ANY(v_target_venue_id_texts)
  FOR UPDATE;

  WITH ownership_conflicts AS (
    SELECT
      v.id AS venue_id,
      v.business_id AS business_id,
      lower(btrim(coalesce(v.owner_email, ''))) AS owner_email
    FROM public.venues v
    WHERE v.id::text = ANY(v_target_venue_id_texts)
      AND lower(btrim(coalesce(v.admin_status, 'active'))) = 'active'
      AND (
        (v.business_id IS NOT NULL AND v.business_id::text <> p_business_id::text)
        OR (
          v.business_id IS NULL
          AND btrim(coalesce(v.owner_email, '')) <> ''
          AND lower(btrim(coalesce(v.owner_email, ''))) <> v_owner_email
        )
      )

    UNION ALL

    SELECT
      vc.venue_id AS venue_id,
      vc.business_id AS business_id,
      lower(btrim(coalesce(vc.owner_email, ''))) AS owner_email
    FROM public.venue_claims vc
    WHERE vc.venue_id::text = ANY(v_target_venue_id_texts)
      AND (
        lower(btrim(coalesce(vc.approval_status, ''))) IN ('approved', 'pending')
        OR public.gameon_venue_claim_is_open_pending(vc.approval_status)
      )
      AND (
        (vc.business_id IS NOT NULL AND vc.business_id::text <> p_business_id::text)
        OR (
          vc.business_id IS NULL
          AND btrim(coalesce(vc.owner_email, '')) <> ''
          AND lower(btrim(coalesce(vc.owner_email, ''))) <> v_owner_email
        )
      )
  )
  SELECT venue_id, business_id, owner_email
    INTO v_conflicting_venue_id, v_conflicting_business_id, v_conflicting_owner_email
  FROM ownership_conflicts
  LIMIT 1;

  IF v_conflicting_venue_id IS NOT NULL THEN
    RAISE LOG '[BusinessDeleteDuplicateDebug] conflicting_venue_id=% conflicting_business_id=% conflicting_owner_email=% target_business_id=% target_owner_email=%',
      v_conflicting_venue_id,
      coalesce(v_conflicting_business_id::text, 'nil'),
      coalesce(v_conflicting_owner_email, ''),
      p_business_id,
      v_owner_email;
    RAISE EXCEPTION 'duplicate_venue_other_business'
      USING ERRCODE = 'P0001';
  END IF;

  SELECT coalesce(array_agg(id), ARRAY[]::uuid[])
    INTO v_business_venue_ids
  FROM public.venues
  WHERE id::text = ANY(v_target_venue_id_texts)
    AND lower(btrim(coalesce(origin_type, 'business'))) <> 'community';
  v_business_venue_id_texts := ARRAY(SELECT unnest(v_business_venue_ids)::text);

  SELECT coalesce(array_agg(id), ARRAY[]::uuid[])
    INTO v_community_venue_ids
  FROM public.venues
  WHERE id::text = ANY(v_target_venue_id_texts)
    AND lower(btrim(coalesce(origin_type, 'business'))) = 'community';
  v_community_venue_id_texts := ARRAY(SELECT unnest(v_community_venue_ids)::text);

  SELECT coalesce(array_agg(DISTINCT ve.id), ARRAY[]::uuid[])
    INTO v_event_ids
  FROM public.venue_events ve
  WHERE ve.venue_id::text = ANY(v_target_venue_id_texts)
     OR EXISTS (
       SELECT 1
       FROM public.venues tv
       WHERE tv.id::text = ANY(v_target_venue_id_texts)
         AND ve.venue_id IS NULL
         AND btrim(coalesce(tv.owner_email, '')) <> ''
         AND lower(btrim(coalesce(ve.owner_email, ''))) = lower(btrim(tv.owner_email))
         AND lower(btrim(coalesce(ve.venue_name, ''))) = lower(btrim(coalesce(tv.venue_name, '')))
     );
  v_event_id_texts := ARRAY(SELECT unnest(v_event_ids)::text);

  SELECT coalesce(array_agg(id), ARRAY[]::uuid[])
    INTO v_comment_ids
  FROM public.venue_event_comments
  WHERE venue_event_id::text = ANY(v_event_id_texts);
  v_comment_id_texts := ARRAY(SELECT unnest(v_comment_ids)::text);

  SELECT coalesce(array_agg(DISTINCT storage.path), ARRAY[]::text[])
    INTO v_storage_paths
  FROM public.venues v
  CROSS JOIN LATERAL unnest(ARRAY[
    public.gameon_storage_path_from_public_url(v.cover_photo_url, 'venue-photos'),
    public.gameon_storage_path_from_public_url(v.menu_photo_url, 'venue-photos'),
    public.gameon_storage_path_from_public_url(v.cover_photo_thumbnail_url, 'venue-photos'),
    public.gameon_storage_path_from_public_url(v.menu_photo_thumbnail_url, 'venue-photos')
  ]) AS storage(path)
  WHERE v.id::text = ANY(v_target_venue_id_texts)
    AND storage.path IS NOT NULL
    AND btrim(storage.path) <> '';

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
  SELECT
    CASE WHEN lower(btrim(coalesce(v.origin_type, 'business'))) = 'community' THEN 'release' ELSE 'hardDelete' END,
    v.id,
    p_business_id,
    v_uid,
    NULLIF(v_email, ''),
    v.venue_name,
    jsonb_build_object(
      'venue_id', v.id,
      'business_id', p_business_id,
      'venue_name', v.venue_name,
      'origin_type', v.origin_type,
      'action', CASE WHEN lower(btrim(coalesce(v.origin_type, 'business'))) = 'community' THEN 'release' ELSE 'hardDelete' END,
      'deleted_at', now()
    ),
    coalesce((
      SELECT array_agg(DISTINCT ve.id)
      FROM public.venue_events ve
      WHERE ve.venue_id::text = v.id::text
         OR (
           ve.venue_id IS NULL
           AND btrim(coalesce(v.owner_email, '')) <> ''
           AND lower(btrim(coalesce(ve.owner_email, ''))) = lower(btrim(v.owner_email))
           AND lower(btrim(coalesce(ve.venue_name, ''))) = lower(btrim(coalesce(v.venue_name, '')))
         )
    ), ARRAY[]::uuid[]),
    coalesce((
      SELECT array_agg(DISTINCT storage.path)
      FROM unnest(ARRAY[
        public.gameon_storage_path_from_public_url(v.cover_photo_url, 'venue-photos'),
        public.gameon_storage_path_from_public_url(v.menu_photo_url, 'venue-photos'),
        public.gameon_storage_path_from_public_url(v.cover_photo_thumbnail_url, 'venue-photos'),
        public.gameon_storage_path_from_public_url(v.menu_photo_thumbnail_url, 'venue-photos')
      ]) AS storage(path)
      WHERE storage.path IS NOT NULL
        AND btrim(storage.path) <> ''
    ), ARRAY[]::text[])
  FROM public.venues v
  WHERE v.id::text = ANY(v_target_venue_id_texts);
  GET DIAGNOSTICS v_count = ROW_COUNT;
  v_counts := v_counts || jsonb_build_object('business_venue_deletion_audit', v_count);

  DELETE FROM public.venue_event_comment_reactions
  WHERE comment_id::text = ANY(v_comment_id_texts);
  GET DIAGNOSTICS v_count = ROW_COUNT;
  v_counts := v_counts || jsonb_build_object('venue_event_comment_reactions', v_count);

  DELETE FROM public.venue_event_comment_likes
  WHERE comment_id::text = ANY(v_comment_id_texts);
  GET DIAGNOSTICS v_count = ROW_COUNT;
  v_counts := v_counts || jsonb_build_object('venue_event_comment_likes', v_count);

  DELETE FROM public.comment_reports
  WHERE comment_id::text = ANY(v_comment_id_texts)
     OR venue_event_id::text = ANY(v_event_id_texts);
  GET DIAGNOSTICS v_count = ROW_COUNT;
  v_counts := v_counts || jsonb_build_object('comment_reports', v_count);

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
  WHERE business_id::text = p_business_id::text
     OR venue_id::text = ANY(v_target_venue_id_texts)
     OR original_venue_event_id::text = ANY(v_event_id_texts);
  GET DIAGNOSTICS v_count = ROW_COUNT;
  v_counts := v_counts || jsonb_build_object('business_game_history', v_count);

  DELETE FROM public.venue_events
  WHERE id::text = ANY(v_event_id_texts);
  GET DIAGNOSTICS v_count = ROW_COUNT;
  v_counts := v_counts || jsonb_build_object('venue_events', v_count);

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
  WHERE id::text = ANY(v_community_venue_id_texts);
  GET DIAGNOSTICS v_count = ROW_COUNT;
  v_counts := v_counts || jsonb_build_object('community_venues_released', v_count);

  UPDATE public.venue_claims
  SET approval_status = 'cancelled',
      business_id = NULL,
      owner_email = NULL
  WHERE id::text = ANY(v_pending_community_claim_id_texts);
  GET DIAGNOSTICS v_count = ROW_COUNT;
  v_counts := v_counts || jsonb_build_object('pending_community_claims_cancelled', v_count);

  UPDATE public.venue_claims
  SET approval_status = 'released',
      business_id = NULL,
      owner_email = NULL
  WHERE venue_id::text = ANY(v_community_venue_id_texts)
    AND lower(btrim(coalesce(approval_status, ''))) = 'approved'
    AND (
      id::text = ANY(v_claim_scope_id_texts)
      OR business_id::text = p_business_id::text
      OR (v_owner_email <> '' AND lower(btrim(coalesce(owner_email, ''))) = v_owner_email)
    );
  GET DIAGNOSTICS v_count = ROW_COUNT;
  v_counts := v_counts || jsonb_build_object('community_venue_claims_released', v_count);

  DELETE FROM public.favorite_venues
  WHERE venue_id::text = ANY(v_business_venue_id_texts);
  GET DIAGNOSTICS v_count = ROW_COUNT;
  v_counts := v_counts || jsonb_build_object('favorite_venues', v_count);

  UPDATE public.user_profiles
  SET home_crowd_venue_id = NULL,
      home_crowd_set_at = NULL
  WHERE home_crowd_venue_id::text = ANY(v_business_venue_id_texts);
  GET DIAGNOSTICS v_count = ROW_COUNT;
  v_counts := v_counts || jsonb_build_object('home_crowd_profiles_unlinked', v_count);

  DELETE FROM public.venue_reports
  WHERE venue_id::text = ANY(v_business_venue_id_texts);
  GET DIAGNOSTICS v_count = ROW_COUNT;
  v_counts := v_counts || jsonb_build_object('venue_reports', v_count);

  DELETE FROM public.venues
  WHERE id::text = ANY(v_business_venue_id_texts);
  GET DIAGNOSTICS v_count = ROW_COUNT;
  v_counts := v_counts || jsonb_build_object('business_venues_deleted', v_count);

  UPDATE public.venue_claims
  SET venue_id = NULL,
      business_id = NULL,
      owner_email = NULL,
      approval_status = 'cancelled'
  WHERE id::text = ANY(v_pending_business_claim_id_texts);
  GET DIAGNOSTICS v_count = ROW_COUNT;
  v_counts := v_counts || jsonb_build_object('pending_business_claims_cancelled', v_count);

  UPDATE public.venue_claims
  SET venue_id = NULL,
      business_id = NULL,
      owner_email = NULL,
      approval_status = CASE
        WHEN lower(btrim(coalesce(approval_status, ''))) = 'approved' THEN 'business_deleted'
        ELSE 'business_deleted'
      END
  WHERE venue_id::text = ANY(v_business_venue_id_texts)
     OR business_id::text = p_business_id::text;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  v_counts := v_counts || jsonb_build_object('business_venue_claims_cleared', v_count);

  UPDATE public.venue_claims
  SET venue_id = CASE
        WHEN lower(btrim(coalesce(approval_status, ''))) IN ('approved', 'released')
          AND venue_id::text = ANY(v_community_venue_id_texts)
          THEN venue_id
        ELSE NULL
      END,
      business_id = NULL,
      owner_email = NULL,
      approval_status = CASE
        WHEN lower(btrim(coalesce(approval_status, ''))) = 'approved' THEN 'released'
        WHEN lower(btrim(coalesce(approval_status, ''))) IN ('released', 'cancelled', 'business_deleted')
          THEN lower(btrim(coalesce(approval_status, '')))
        ELSE 'business_deleted'
      END
  WHERE id::text = ANY(v_claim_scope_id_texts)
     OR business_id::text = p_business_id::text
     OR (v_owner_email <> '' AND lower(btrim(coalesce(owner_email, ''))) = v_owner_email);
  GET DIAGNOSTICS v_count = ROW_COUNT;
  v_counts := v_counts || jsonb_build_object('remaining_venue_claims_cleared', v_count);

  DELETE FROM public.friendships
  WHERE (requester_entity_type = 'business' AND requester_id::text = p_business_id::text)
     OR (addressee_entity_type = 'business' AND addressee_id::text = p_business_id::text);
  GET DIAGNOSTICS v_count = ROW_COUNT;
  v_counts := v_counts || jsonb_build_object('business_friendships_deleted', v_count);

  DELETE FROM public.businesses
  WHERE id::text = p_business_id::text;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  v_counts := v_counts || jsonb_build_object('businesses_deleted', v_count);

  IF EXISTS (SELECT 1 FROM public.businesses b WHERE b.id::text = p_business_id::text) THEN
    RAISE EXCEPTION 'Business deletion verification failed: business still exists %', p_business_id
      USING ERRCODE = 'P0001';
  END IF;

  IF EXISTS (SELECT 1 FROM public.venues v WHERE v.id::text = ANY(v_business_venue_id_texts)) THEN
    RAISE EXCEPTION 'Business venue deletion verification failed for business: %', p_business_id
      USING ERRCODE = 'P0001';
  END IF;

  IF EXISTS (SELECT 1 FROM public.venue_events ve WHERE ve.id::text = ANY(v_event_id_texts)) THEN
    RAISE EXCEPTION 'Venue event deletion verification failed for business: %', p_business_id
      USING ERRCODE = 'P0001';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.venues v
    WHERE v.id::text = ANY(v_community_venue_id_texts)
      AND NOT (
        lower(btrim(coalesce(v.origin_type, ''))) = 'community'
        AND lower(btrim(coalesce(v.admin_status, 'active'))) = 'active'
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
  ) THEN
    RAISE EXCEPTION 'Community venue release verification failed for business: %', p_business_id
      USING ERRCODE = 'P0001';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.venue_claims vc
    WHERE vc.venue_id::text = ANY(v_community_venue_id_texts)
      AND lower(btrim(coalesce(vc.approval_status, ''))) = 'approved'
  ) THEN
    RAISE EXCEPTION 'Community venue claim release verification failed for business: %', p_business_id
      USING ERRCODE = 'P0001';
  END IF;

  SELECT
    count(*) FILTER (
      WHERE lower(btrim(coalesce(vc.approval_status, ''))) IN ('approved', 'pending')
         OR public.gameon_venue_claim_is_open_pending(vc.approval_status)
    ),
    count(*) FILTER (WHERE lower(btrim(coalesce(vc.approval_status, ''))) = 'released'),
    count(*) FILTER (WHERE lower(btrim(coalesce(vc.approval_status, ''))) = 'cancelled'),
    count(*) FILTER (WHERE lower(btrim(coalesce(vc.approval_status, ''))) = 'business_deleted')
  INTO
    v_active_claims_remaining,
    v_released_claims,
    v_cancelled_claims,
    v_business_deleted_claims
  FROM public.venue_claims vc
  WHERE vc.id::text = ANY(v_claim_scope_id_texts)
     OR vc.business_id::text = p_business_id::text
     OR (
       v_owner_email <> ''
       AND lower(btrim(coalesce(vc.owner_email, ''))) = v_owner_email
     )
     OR (
       v_owner_user_id_text <> ''
       AND EXISTS (
         SELECT 1
         FROM public.venues v
         WHERE v.id::text = vc.venue_id::text
           AND v.owner_user_id::text = v_owner_user_id_text
       )
     );

  RAISE LOG '[BusinessDeleteAudit] activeClaimsRemaining=% releasedClaims=% cancelledClaims=% businessDeletedClaims=%',
    v_active_claims_remaining,
    v_released_claims,
    v_cancelled_claims,
    v_business_deleted_claims;

  IF v_active_claims_remaining > 0 THEN
    RAISE EXCEPTION 'Business deletion active claim verification failed for business: % active_claims=%',
      p_business_id,
      v_active_claims_remaining
      USING ERRCODE = 'P0001';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.venue_claims vc
    WHERE vc.business_id::text = p_business_id::text
       OR (
         v_owner_email <> ''
         AND lower(btrim(coalesce(vc.owner_email, ''))) = v_owner_email
       )
  ) THEN
    RAISE EXCEPTION 'Venue claim unlink verification failed for business: %', p_business_id
      USING ERRCODE = 'P0001';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.venue_claims vc
    WHERE vc.id::text = ANY(v_pending_claim_id_texts)
      AND public.gameon_venue_claim_is_open_pending(vc.approval_status)
  ) THEN
    RAISE EXCEPTION 'Pending claim cancellation verification failed for business: %', p_business_id
      USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO public.business_account_deletion_audit (
    business_id,
    deleted_by,
    deleted_by_email,
    business_snapshot,
    released_venue_ids,
    hard_deleted_venue_ids,
    deleted_event_ids,
    deleted_storage_paths,
    deleted_counts
  )
  VALUES (
    p_business_id,
    v_uid,
    NULLIF(v_email, ''),
    jsonb_build_object(
      'business_id', v_business.id,
      'display_name', v_business.display_name,
      'owner_user_id', v_business.owner_user_id,
      'owner_email', v_business.owner_email,
      'admin_status', v_business.admin_status,
      'deleted_at', now()
    ),
    v_community_venue_ids,
    v_business_venue_ids,
    v_event_ids,
    v_storage_paths,
    v_counts
  );

  RETURN jsonb_build_object(
    'ok', true,
    'business_id', p_business_id,
    'business_name', v_business.display_name,
    'released_venue_ids', v_community_venue_ids,
    'hard_deleted_venue_ids', v_business_venue_ids,
    'deleted_event_ids', v_event_ids,
    'deleted_storage_paths', v_storage_paths,
    'deleted_counts', v_counts,
    'business_venue_count', cardinality(v_business_venue_ids),
    'community_venue_count', cardinality(v_community_venue_ids),
    'event_count', cardinality(v_event_ids),
    'photo_count', cardinality(v_storage_paths),
    'pending_claim_count', cardinality(v_pending_claim_ids),
    'cancelled_claim_ids', v_pending_claim_ids
  );
END;
$$;

REVOKE ALL ON FUNCTION public.business_account_deletion_preview(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.delete_business_account_cascade(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.business_account_deletion_preview(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_business_account_cascade(uuid) TO authenticated;

COMMENT ON FUNCTION public.business_account_deletion_preview(uuid) IS
  'Read-only preview of business account deletion impact. Does not mutate data.';

COMMENT ON FUNCTION public.delete_business_account_cascade(uuid) IS
  'Transactionally deletes a business account, hard-deletes business-created venues, releases community venues, and returns exact Storage API paths.';
