-- Expired Game/Social Cleanup Phase 2A.
--
-- Non-destructive dry-run preview only.
-- This migration does not schedule cron, mutate table data, call existing purge
-- functions, alter account deletion, or touch DMs / pickup games / live matches.

CREATE OR REPLACE FUNCTION public.preview_expired_game_social_cleanup(
  p_now timestamptz DEFAULT now(),
  p_limit integer DEFAULT 500
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
  v_venue_event_comments_count integer := 0;
  v_venue_event_interests_count integer := 0;
  v_venue_event_vibes_count integer := 0;
  v_venue_event_comment_likes_count integer := 0;
  v_venue_event_comment_reactions_count integer := 0;
  v_comment_reports_count integer := 0;
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

  RETURN jsonb_build_object(
    'venue_events_targeted', cardinality(v_event_ids),
    'venue_event_comments_targeted', v_venue_event_comments_count,
    'venue_event_interests_targeted', v_venue_event_interests_count,
    'venue_event_vibes_targeted', v_venue_event_vibes_count,
    'venue_event_comment_likes_targeted', v_venue_event_comment_likes_count,
    'venue_event_comment_reactions_targeted', v_venue_event_comment_reactions_count,
    'comment_reports_preserved', v_comment_reports_count
  );
END;
$$;

COMMENT ON FUNCTION public.preview_expired_game_social_cleanup(timestamptz, integer) IS
  'Dry-run-only preview for expired venue game/social cleanup. Returns target counts and preserves all table data.';

REVOKE ALL ON FUNCTION public.preview_expired_game_social_cleanup(timestamptz, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.preview_expired_game_social_cleanup(timestamptz, integer) FROM anon;
REVOKE ALL ON FUNCTION public.preview_expired_game_social_cleanup(timestamptz, integer) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.preview_expired_game_social_cleanup(timestamptz, integer) TO service_role;
