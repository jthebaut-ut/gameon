-- Expired Game/Social Cleanup Phase 2B.
--
-- Safe cleanup function only. No cron is scheduled here.
-- Defaults to dry-run and does not call legacy purge_expired_venue_events().

CREATE TABLE IF NOT EXISTS public.expired_venue_event_moderation_archive (
  original_venue_event_id text NOT NULL,
  original_comment_id uuid,
  reporter_email text,
  report_reason text,
  comment_text_snapshot text,
  commenter_email_snapshot text,
  moderation_report_count integer,
  moderation_last_reported_at timestamptz,
  moderation_alert_sent_at timestamptz,
  archived_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.expired_venue_event_moderation_archive IS
  'Snapshots reported expired venue-event Fan Chat context before temporary comment rows are removed.';

REVOKE ALL ON TABLE public.expired_venue_event_moderation_archive FROM PUBLIC;
REVOKE ALL ON TABLE public.expired_venue_event_moderation_archive FROM anon;
REVOKE ALL ON TABLE public.expired_venue_event_moderation_archive FROM authenticated;
GRANT SELECT, INSERT ON TABLE public.expired_venue_event_moderation_archive TO service_role;

CREATE OR REPLACE FUNCTION public.cleanup_expired_game_social_phase2(
  p_now timestamptz DEFAULT now(),
  p_limit integer DEFAULT 500,
  p_dry_run boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_event_ids uuid[] := ARRAY[]::uuid[];
  v_event_id_texts text[] := ARRAY[]::text[];
  v_comment_ids uuid[] := ARRAY[]::uuid[];
  v_limit integer := greatest(coalesce(p_limit, 500), 0);
  v_counts jsonb := '{}'::jsonb;
  v_venue_event_comments_count integer := 0;
  v_venue_event_interests_count integer := 0;
  v_venue_event_vibes_count integer := 0;
  v_venue_event_comment_likes_count integer := 0;
  v_venue_event_comment_reactions_count integer := 0;
  v_comment_reports_count integer := 0;
  v_archive_inserted_count integer := 0;
  v_business_history_inserted_count integer := 0;
  v_deleted_count integer := 0;
BEGIN
  SELECT coalesce(array_agg(expired.id), ARRAY[]::uuid[])
    INTO v_event_ids
  FROM (
    SELECT ve.id
    FROM public.venue_events ve
    WHERE ve.purged_at IS NULL
      AND ve.purge_after_at IS NOT NULL
      AND ve.purge_after_at <= p_now
    ORDER BY ve.purge_after_at ASC, ve.id ASC
    LIMIT v_limit
  ) expired;

  SELECT coalesce(array_agg(event_id_text), ARRAY[]::text[])
    INTO v_event_id_texts
  FROM (
    SELECT unnest(v_event_ids)::text AS event_id_text
  ) ids;

  SELECT coalesce(array_agg(c.id), ARRAY[]::uuid[])
    INTO v_comment_ids
  FROM public.venue_event_comments c
  WHERE c.venue_event_id::text = ANY(v_event_id_texts);

  v_venue_event_comments_count := cardinality(v_comment_ids);

  SELECT count(*)::integer
    INTO v_venue_event_interests_count
  FROM public.venue_event_interests i
  WHERE i.venue_event_id::text = ANY(v_event_id_texts);

  SELECT count(*)::integer
    INTO v_venue_event_vibes_count
  FROM public.venue_event_vibes v
  WHERE v.venue_event_id::text = ANY(v_event_id_texts);

  SELECT count(*)::integer
    INTO v_venue_event_comment_likes_count
  FROM public.venue_event_comment_likes l
  WHERE l.comment_id = ANY(v_comment_ids);

  SELECT count(*)::integer
    INTO v_venue_event_comment_reactions_count
  FROM public.venue_event_comment_reactions r
  WHERE r.comment_id = ANY(v_comment_ids);

  SELECT count(*)::integer
    INTO v_comment_reports_count
  FROM public.comment_reports cr
  WHERE cr.comment_id = ANY(v_comment_ids)
     OR cr.venue_event_id::text = ANY(v_event_id_texts);

  v_counts := jsonb_build_object(
    'venue_events_targeted', cardinality(v_event_ids),
    'venue_event_comments_targeted', v_venue_event_comments_count,
    'venue_event_interests_targeted', v_venue_event_interests_count,
    'venue_event_vibes_targeted', v_venue_event_vibes_count,
    'venue_event_comment_likes_targeted', v_venue_event_comment_likes_count,
    'venue_event_comment_reactions_targeted', v_venue_event_comment_reactions_count,
    'comment_reports_preserved', v_comment_reports_count
  );

  IF p_dry_run THEN
    RETURN v_counts;
  END IF;

  INSERT INTO public.expired_venue_event_moderation_archive (
    original_venue_event_id,
    original_comment_id,
    reporter_email,
    report_reason,
    comment_text_snapshot,
    commenter_email_snapshot,
    moderation_report_count,
    moderation_last_reported_at,
    moderation_alert_sent_at
  )
  SELECT
    coalesce(cr.venue_event_id::text, c.venue_event_id::text) AS original_venue_event_id,
    cr.comment_id,
    cr.reporter_email,
    cr.reason,
    c.comment,
    c.user_email,
    c.moderation_report_count,
    c.moderation_last_reported_at,
    c.moderation_alert_sent_at
  FROM public.comment_reports cr
  LEFT JOIN public.venue_event_comments c
    ON c.id = cr.comment_id
  WHERE cr.comment_id = ANY(v_comment_ids)
     OR cr.venue_event_id::text = ANY(v_event_id_texts);
  GET DIAGNOSTICS v_archive_inserted_count = ROW_COUNT;

  INSERT INTO public.business_game_history (
    original_venue_event_id,
    business_id,
    venue_id,
    venue_name,
    event_title,
    sport,
    scheduled_start_at,
    event_date,
    cleanup_delay_hours,
    attendance_count,
    comment_count,
    created_at,
    purged_at
  )
  SELECT
    ve.id,
    v.business_id,
    ve.venue_id,
    coalesce(nullif(trim(v.venue_name), ''), nullif(trim(ve.venue_name), '')),
    ve.event_title,
    ve.sport,
    ve.scheduled_start_at,
    CASE
      WHEN ve.event_date IS NULL THEN NULL
      ELSE trim(ve.event_date::text)::date
    END,
    ve.cleanup_delay_hours,
    coalesce((
      SELECT count(*)::integer
      FROM public.venue_event_interests i
      WHERE i.venue_event_id::text = ve.id::text
    ), 0),
    coalesce((
      SELECT count(*)::integer
      FROM public.venue_event_comments c
      WHERE c.venue_event_id::text = ve.id::text
    ), 0),
    coalesce(ve.created_at, now()),
    now()
  FROM public.venue_events ve
  LEFT JOIN public.venues v ON v.id = ve.venue_id
  WHERE ve.id = ANY(v_event_ids);
  GET DIAGNOSTICS v_business_history_inserted_count = ROW_COUNT;

  DELETE FROM public.venue_event_comment_reactions r
  WHERE r.comment_id = ANY(v_comment_ids);
  GET DIAGNOSTICS v_deleted_count = ROW_COUNT;
  v_counts := v_counts || jsonb_build_object('venue_event_comment_reactions_deleted', v_deleted_count);

  DELETE FROM public.venue_event_comment_likes l
  WHERE l.comment_id = ANY(v_comment_ids);
  GET DIAGNOSTICS v_deleted_count = ROW_COUNT;
  v_counts := v_counts || jsonb_build_object('venue_event_comment_likes_deleted', v_deleted_count);

  -- Intentionally do not delete comment_reports; the archive above preserves
  -- reported comment context before temporary Fan Chat rows are removed.
  DELETE FROM public.venue_event_comments c
  WHERE c.venue_event_id::text = ANY(v_event_id_texts);
  GET DIAGNOSTICS v_deleted_count = ROW_COUNT;
  v_counts := v_counts || jsonb_build_object('venue_event_comments_deleted', v_deleted_count);

  DELETE FROM public.venue_event_vibes v
  WHERE v.venue_event_id::text = ANY(v_event_id_texts);
  GET DIAGNOSTICS v_deleted_count = ROW_COUNT;
  v_counts := v_counts || jsonb_build_object('venue_event_vibes_deleted', v_deleted_count);

  DELETE FROM public.venue_event_interests i
  WHERE i.venue_event_id::text = ANY(v_event_id_texts);
  GET DIAGNOSTICS v_deleted_count = ROW_COUNT;
  v_counts := v_counts || jsonb_build_object('venue_event_interests_deleted', v_deleted_count);

  DELETE FROM public.venue_events ve
  WHERE ve.id = ANY(v_event_ids);
  GET DIAGNOSTICS v_deleted_count = ROW_COUNT;

  RETURN v_counts || jsonb_build_object(
    'dry_run', false,
    'archive_rows_inserted', v_archive_inserted_count,
    'business_game_history_inserted', v_business_history_inserted_count,
    'venue_events_deleted', v_deleted_count
  );
END;
$$;

COMMENT ON FUNCTION public.cleanup_expired_game_social_phase2(timestamptz, integer, boolean) IS
  'Dry-run-first safe cleanup for expired venue games and temporary social rows. Preserves comment_reports and archives reported Fan Chat context before deleting temporary comments.';

REVOKE ALL ON FUNCTION public.cleanup_expired_game_social_phase2(timestamptz, integer, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.cleanup_expired_game_social_phase2(timestamptz, integer, boolean) FROM anon;
REVOKE ALL ON FUNCTION public.cleanup_expired_game_social_phase2(timestamptz, integer, boolean) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.cleanup_expired_game_social_phase2(timestamptz, integer, boolean) TO service_role;
