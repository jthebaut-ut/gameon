-- Fan user account deletion Phase 1.
-- Adds soft-delete/anonymization support and a schema-defensive RPC.
--
-- This migration is intentionally non-destructive at migration time: it only
-- adds metadata columns/indexes and defines public.request_delete_my_account().
-- The RPC preserves chat, Fan Chat, report, and moderation integrity by keeping
-- direct_messages, direct_conversations, reports, support_requests, and
-- venue_event_comments rows. User identity surfaces are anonymized instead.

ALTER TABLE public.user_profiles
  ADD COLUMN IF NOT EXISTS is_deleted boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS deleted_at timestamptz,
  ADD COLUMN IF NOT EXISTS anonymized_at timestamptz,
  ADD COLUMN IF NOT EXISTS deletion_requested_at timestamptz;

CREATE INDEX IF NOT EXISTS idx_user_profiles_is_deleted
  ON public.user_profiles (is_deleted);

CREATE INDEX IF NOT EXISTS idx_user_profiles_deleted_at
  ON public.user_profiles (deleted_at DESC)
  WHERE deleted_at IS NOT NULL;

COMMENT ON COLUMN public.user_profiles.is_deleted IS
  'Soft-delete marker for fan account deletion. Deleted users remain as anonymized rows to preserve foreign keys and thread integrity.';

COMMENT ON COLUMN public.user_profiles.deleted_at IS
  'Timestamp when the fan account was soft-deleted.';

COMMENT ON COLUMN public.user_profiles.anonymized_at IS
  'Timestamp when personally identifying profile fields were anonymized.';

COMMENT ON COLUMN public.user_profiles.deletion_requested_at IS
  'Timestamp when the authenticated user requested account deletion.';

CREATE OR REPLACE FUNCTION public.request_delete_my_account()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_email text := lower(btrim(coalesce(auth.jwt() ->> 'email', '')));
  v_deleted_email text;
  v_avatar_storage_paths text[] := ARRAY[]::text[];
  v_avatar_exprs text[] := ARRAY[]::text[];
  v_profile_set_clauses text[] := ARRAY[]::text[];
  v_friendship_set_clauses text[] := ARRAY[]::text[];
  v_pickup_game_set_clauses text[] := ARRAY[]::text[];
  v_pickup_request_set_clauses text[] := ARRAY[]::text[];
  v_notification_where_clauses text[] := ARRAY[]::text[];
  v_sql text;
  v_count integer := 0;
  v_counts jsonb := '{}'::jsonb;
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

  v_email := coalesce(v_email, '');
  v_deleted_email := 'deleted-user-' || replace(v_uid::text, '-', '') || '@deleted.fangeo.local';

  IF to_regclass('public.user_profiles') IS NULL THEN
    RAISE EXCEPTION 'user_profiles table is required for account deletion'
      USING ERRCODE = 'P0002';
  END IF;

  -- Collect exact avatar object paths before profile URLs are cleared. Storage
  -- deletion remains best-effort outside this transaction, using returned paths.
  BEGIN
    IF to_regprocedure('public.gameon_storage_path_from_public_url(text,text)') IS NOT NULL THEN
      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'avatar_url'
      ) THEN
        v_avatar_exprs := v_avatar_exprs || ARRAY['public.gameon_storage_path_from_public_url(NULLIF(btrim(up.avatar_url), ''''), ''user-avatars'')'];
      END IF;

      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'avatar_thumbnail_url'
      ) THEN
        v_avatar_exprs := v_avatar_exprs || ARRAY['public.gameon_storage_path_from_public_url(NULLIF(btrim(up.avatar_thumbnail_url), ''''), ''user-avatars'')'];
      END IF;

      IF array_length(v_avatar_exprs, 1) IS NOT NULL THEN
        v_sql := format(
          'SELECT coalesce(array_agg(DISTINCT storage.path), ARRAY[]::text[])
             FROM public.user_profiles up
             CROSS JOIN LATERAL unnest(ARRAY[%s]::text[]) AS storage(path)
            WHERE up.id = $1
              AND storage.path IS NOT NULL
              AND btrim(storage.path) <> ''''',
          array_to_string(v_avatar_exprs, ', ')
        );
        EXECUTE v_sql INTO v_avatar_storage_paths USING v_uid;
      END IF;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'request_delete_my_account: storage cleanup skipped for user %: %', v_uid, SQLERRM;
    v_avatar_storage_paths := ARRAY[]::text[];
  END;

  -- Build the profile anonymization UPDATE from columns that actually exist.
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'is_deleted') THEN
    v_profile_set_clauses := v_profile_set_clauses || ARRAY['is_deleted = true'];
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'deleted_at') THEN
    v_profile_set_clauses := v_profile_set_clauses || ARRAY['deleted_at = now()'];
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'anonymized_at') THEN
    v_profile_set_clauses := v_profile_set_clauses || ARRAY['anonymized_at = now()'];
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'deletion_requested_at') THEN
    v_profile_set_clauses := v_profile_set_clauses || ARRAY['deletion_requested_at = coalesce(deletion_requested_at, now())'];
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'display_name') THEN
    v_profile_set_clauses := array_append(v_profile_set_clauses, format('display_name = %L', 'Deleted User'));
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'email') THEN
    v_profile_set_clauses := array_append(v_profile_set_clauses, format('email = %L', v_deleted_email));
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'username') THEN
    v_profile_set_clauses := v_profile_set_clauses || ARRAY['username = NULL'];
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'handle') THEN
    v_profile_set_clauses := v_profile_set_clauses || ARRAY['handle = NULL'];
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'bio') THEN
    v_profile_set_clauses := v_profile_set_clauses || ARRAY['bio = NULL'];
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'avatar_url') THEN
    v_profile_set_clauses := v_profile_set_clauses || ARRAY['avatar_url = NULL'];
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'avatar_thumbnail_url') THEN
    v_profile_set_clauses := v_profile_set_clauses || ARRAY['avatar_thumbnail_url = NULL'];
  END IF;
  -- Do not update normalized/generated columns directly. They recompute from
  -- display_name / username, or are maintained by legacy triggers where present.
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'discoverable_by_fans') THEN
    v_profile_set_clauses := v_profile_set_clauses || ARRAY['discoverable_by_fans = false'];
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'live_visibility_enabled') THEN
    v_profile_set_clauses := v_profile_set_clauses || ARRAY['live_visibility_enabled = false'];
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'selected_live_visibility_friend_ids') THEN
    v_profile_set_clauses := v_profile_set_clauses || ARRAY['selected_live_visibility_friend_ids = ARRAY[]::uuid[]'];
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'fan_identity_preferences') THEN
    v_profile_set_clauses := v_profile_set_clauses || ARRAY['fan_identity_preferences = ''{}''::jsonb'];
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'home_crowd_venue_id') THEN
    v_profile_set_clauses := v_profile_set_clauses || ARRAY['home_crowd_venue_id = NULL'];
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'home_crowd_set_at') THEN
    v_profile_set_clauses := v_profile_set_clauses || ARRAY['home_crowd_set_at = NULL'];
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'active_session_id') THEN
    v_profile_set_clauses := v_profile_set_clauses || ARRAY['active_session_id = NULL'];
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'active_session_updated_at') THEN
    v_profile_set_clauses := v_profile_set_clauses || ARRAY['active_session_updated_at = NULL'];
  END IF;

  IF array_length(v_profile_set_clauses, 1) IS NOT NULL THEN
    v_sql := format(
      'UPDATE public.user_profiles SET %s WHERE id = $1',
      array_to_string(v_profile_set_clauses, ', ')
    );
    EXECUTE v_sql USING v_uid;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_counts := v_counts || jsonb_build_object('user_profiles_anonymized', v_count);
  ELSE
    v_counts := v_counts || jsonb_build_object('user_profiles_anonymized', 0);
  END IF;

  IF to_regclass('public.user_favorite_teams') IS NOT NULL
     AND EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_favorite_teams' AND column_name = 'user_id') THEN
    EXECUTE 'DELETE FROM public.user_favorite_teams WHERE user_id = $1' USING v_uid;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_counts := v_counts || jsonb_build_object('user_favorite_teams_deleted', v_count);
  ELSE
    v_counts := v_counts || jsonb_build_object('user_favorite_teams_deleted', 0);
  END IF;

  IF v_email <> ''
     AND to_regclass('public.favorite_venues') IS NOT NULL
     AND EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'favorite_venues' AND column_name = 'user_email') THEN
    EXECUTE 'DELETE FROM public.favorite_venues WHERE lower(btrim(user_email)) = $1' USING v_email;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_counts := v_counts || jsonb_build_object('favorite_venues_deleted', v_count);
  ELSE
    v_counts := v_counts || jsonb_build_object('favorite_venues_deleted', 0);
  END IF;

  IF v_email <> ''
     AND to_regclass('public.venue_event_interests') IS NOT NULL
     AND EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'venue_event_interests' AND column_name = 'user_email') THEN
    EXECUTE 'DELETE FROM public.venue_event_interests WHERE lower(btrim(user_email)) = $1' USING v_email;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_counts := v_counts || jsonb_build_object('venue_event_interests_deleted', v_count);
  ELSE
    v_counts := v_counts || jsonb_build_object('venue_event_interests_deleted', 0);
  END IF;

  IF v_email <> ''
     AND to_regclass('public.venue_event_vibes') IS NOT NULL
     AND EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'venue_event_vibes' AND column_name = 'user_email') THEN
    EXECUTE 'DELETE FROM public.venue_event_vibes WHERE lower(btrim(user_email)) = $1' USING v_email;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_counts := v_counts || jsonb_build_object('venue_event_vibes_deleted', v_count);
  ELSE
    v_counts := v_counts || jsonb_build_object('venue_event_vibes_deleted', 0);
  END IF;

  IF to_regclass('public.venue_event_comment_likes') IS NOT NULL
     AND EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'venue_event_comment_likes' AND column_name = 'user_id') THEN
    EXECUTE 'DELETE FROM public.venue_event_comment_likes WHERE user_id = $1' USING v_uid;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_counts := v_counts || jsonb_build_object('venue_event_comment_likes_deleted', v_count);
  ELSE
    v_counts := v_counts || jsonb_build_object('venue_event_comment_likes_deleted', 0);
  END IF;

  IF to_regclass('public.venue_event_comment_reactions') IS NOT NULL
     AND EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'venue_event_comment_reactions' AND column_name = 'user_id') THEN
    EXECUTE 'DELETE FROM public.venue_event_comment_reactions WHERE user_id = $1' USING v_uid;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_counts := v_counts || jsonb_build_object('venue_event_comment_reactions_deleted', v_count);
  ELSE
    v_counts := v_counts || jsonb_build_object('venue_event_comment_reactions_deleted', 0);
  END IF;

  IF to_regclass('public.conversation_read_state') IS NOT NULL
     AND EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'conversation_read_state' AND column_name = 'user_id') THEN
    EXECUTE 'DELETE FROM public.conversation_read_state WHERE user_id = $1' USING v_uid;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_counts := v_counts || jsonb_build_object('conversation_read_state_deleted', v_count);
  ELSE
    v_counts := v_counts || jsonb_build_object('conversation_read_state_deleted', 0);
  END IF;

  -- Preserve legacy Fan Chat comments. This table stores author identity only
  -- as user_email; do not delete rows or mutate comment text/moderation fields.
  IF v_email <> ''
     AND to_regclass('public.venue_event_comments') IS NOT NULL
     AND EXISTS (
       SELECT 1 FROM information_schema.columns
       WHERE table_schema = 'public'
         AND table_name = 'venue_event_comments'
         AND column_name = 'user_email'
     ) THEN
    EXECUTE
      'UPDATE public.venue_event_comments
          SET user_email = $1
        WHERE lower(btrim(user_email)) = $2'
      USING v_deleted_email, v_email;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_counts := v_counts || jsonb_build_object('venue_event_comments_anonymized', v_count);
  ELSE
    v_counts := v_counts || jsonb_build_object('venue_event_comments_anonymized', 0);
  END IF;

  -- Preserve private message rows and direct conversation rows. Archive only the
  -- social friendship edge where the schema supports it.
  IF to_regclass('public.friendships') IS NOT NULL
     AND EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'friendships' AND column_name = 'requester_id')
     AND EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'friendships' AND column_name = 'addressee_id')
     AND EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'friendships' AND column_name = 'status') THEN
    v_friendship_set_clauses := ARRAY['status = ''archived'''];
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'friendships' AND column_name = 'requester_cleared_at') THEN
      v_friendship_set_clauses := v_friendship_set_clauses || ARRAY['requester_cleared_at = now()'];
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'friendships' AND column_name = 'addressee_cleared_at') THEN
      v_friendship_set_clauses := v_friendship_set_clauses || ARRAY['addressee_cleared_at = now()'];
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'friendships' AND column_name = 'responded_at') THEN
      v_friendship_set_clauses := v_friendship_set_clauses || ARRAY['responded_at = coalesce(responded_at, now())'];
    END IF;

    v_sql := format(
      'UPDATE public.friendships SET %s
        WHERE (
          requester_id = $1
          %s
        ) OR (
          addressee_id = $1
          %s
        )',
      array_to_string(v_friendship_set_clauses, ', '),
      CASE
        WHEN EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'friendships' AND column_name = 'requester_entity_type')
          THEN 'AND coalesce(requester_entity_type, ''user'') = ''user'''
        ELSE ''
      END,
      CASE
        WHEN EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'friendships' AND column_name = 'addressee_entity_type')
          THEN 'AND coalesce(addressee_entity_type, ''user'') = ''user'''
        ELSE ''
      END
    );

    BEGIN
      EXECUTE v_sql USING v_uid;
      GET DIAGNOSTICS v_count = ROW_COUNT;
    EXCEPTION WHEN check_violation THEN
      v_sql := replace(v_sql, 'status = ''archived''', 'status = ''declined''');
      EXECUTE v_sql USING v_uid;
      GET DIAGNOSTICS v_count = ROW_COUNT;
    END;
    v_counts := v_counts || jsonb_build_object('friendships_archived', v_count);
  ELSE
    v_counts := v_counts || jsonb_build_object('friendships_archived', 0);
  END IF;

  IF to_regclass('public.pickup_games') IS NOT NULL
     AND EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'pickup_games' AND column_name = 'creator_user_id') THEN
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'pickup_games' AND column_name = 'status') THEN
      v_pickup_game_set_clauses := v_pickup_game_set_clauses || ARRAY['status = ''cancelled'''];
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'pickup_games' AND column_name = 'is_visible') THEN
      v_pickup_game_set_clauses := v_pickup_game_set_clauses || ARRAY['is_visible = false'];
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'pickup_games' AND column_name = 'remove_after_at') THEN
      v_pickup_game_set_clauses := v_pickup_game_set_clauses || ARRAY['remove_after_at = coalesce(remove_after_at, now())'];
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'pickup_games' AND column_name = 'updated_at') THEN
      v_pickup_game_set_clauses := v_pickup_game_set_clauses || ARRAY['updated_at = now()'];
    END IF;

    IF array_length(v_pickup_game_set_clauses, 1) IS NOT NULL THEN
      v_sql := format(
        'UPDATE public.pickup_games SET %s WHERE creator_user_id = $1',
        array_to_string(v_pickup_game_set_clauses, ', ')
      );
      BEGIN
        EXECUTE v_sql USING v_uid;
        GET DIAGNOSTICS v_count = ROW_COUNT;
      EXCEPTION WHEN check_violation THEN
        v_sql := replace(v_sql, 'status = ''cancelled''', 'status = ''removed''');
        BEGIN
          EXECUTE v_sql USING v_uid;
          GET DIAGNOSTICS v_count = ROW_COUNT;
        EXCEPTION WHEN check_violation THEN
          v_sql := replace(v_sql, 'status = ''removed''', 'status = ''expired''');
          BEGIN
            EXECUTE v_sql USING v_uid;
            GET DIAGNOSTICS v_count = ROW_COUNT;
          EXCEPTION WHEN check_violation THEN
            v_pickup_game_set_clauses := array_remove(v_pickup_game_set_clauses, 'status = ''cancelled''');
            IF array_length(v_pickup_game_set_clauses, 1) IS NOT NULL THEN
              v_sql := format(
                'UPDATE public.pickup_games SET %s WHERE creator_user_id = $1',
                array_to_string(v_pickup_game_set_clauses, ', ')
              );
              EXECUTE v_sql USING v_uid;
              GET DIAGNOSTICS v_count = ROW_COUNT;
            ELSE
              v_count := 0;
            END IF;
          END;
        END;
      END;
      v_counts := v_counts || jsonb_build_object('pickup_games_cancelled_hidden', v_count);
    ELSE
      v_counts := v_counts || jsonb_build_object('pickup_games_cancelled_hidden', 0);
    END IF;
  ELSE
    v_counts := v_counts || jsonb_build_object('pickup_games_cancelled_hidden', 0);
  END IF;

  IF to_regclass('public.pickup_game_requests') IS NOT NULL
     AND EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'pickup_game_requests' AND column_name = 'status') THEN
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'pickup_game_requests' AND column_name = 'updated_at') THEN
      v_pickup_request_set_clauses := v_pickup_request_set_clauses || ARRAY['updated_at = now()'];
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'pickup_game_requests' AND column_name = 'responded_at') THEN
      v_pickup_request_set_clauses := v_pickup_request_set_clauses || ARRAY['responded_at = coalesce(responded_at, now())'];
    END IF;

    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'pickup_game_requests' AND column_name = 'requester_user_id') THEN
      BEGIN
        v_sql := format(
          'UPDATE public.pickup_game_requests SET status = ''withdrawn''%s WHERE requester_user_id = $1',
          CASE WHEN array_length(v_pickup_request_set_clauses, 1) IS NULL THEN '' ELSE ', ' || array_to_string(v_pickup_request_set_clauses, ', ') END
        );
        EXECUTE v_sql USING v_uid;
        GET DIAGNOSTICS v_count = ROW_COUNT;
      EXCEPTION WHEN check_violation THEN
        v_sql := format(
          'UPDATE public.pickup_game_requests SET status = ''cancelled''%s WHERE requester_user_id = $1',
          CASE WHEN array_length(v_pickup_request_set_clauses, 1) IS NULL THEN '' ELSE ', ' || array_to_string(v_pickup_request_set_clauses, ', ') END
        );
        EXECUTE v_sql USING v_uid;
        GET DIAGNOSTICS v_count = ROW_COUNT;
      END;
      v_counts := v_counts || jsonb_build_object('pickup_game_requests_withdrawn', v_count);
    ELSE
      v_counts := v_counts || jsonb_build_object('pickup_game_requests_withdrawn', 0);
    END IF;

    IF to_regclass('public.pickup_games') IS NOT NULL
       AND EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'pickup_game_requests' AND column_name = 'pickup_game_id')
       AND EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'pickup_games' AND column_name = 'id')
       AND EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'pickup_games' AND column_name = 'creator_user_id') THEN
      v_sql := format(
        'UPDATE public.pickup_game_requests
            SET status = ''cancelled''%s
          WHERE pickup_game_id IN (
            SELECT id FROM public.pickup_games WHERE creator_user_id = $1
          )',
        CASE WHEN array_length(v_pickup_request_set_clauses, 1) IS NULL THEN '' ELSE ', ' || array_to_string(v_pickup_request_set_clauses, ', ') END
      );
      EXECUTE v_sql USING v_uid;
      GET DIAGNOSTICS v_count = ROW_COUNT;
      v_counts := v_counts || jsonb_build_object('pickup_game_requests_cancelled_for_created_games', v_count);
    ELSE
      v_counts := v_counts || jsonb_build_object('pickup_game_requests_cancelled_for_created_games', 0);
    END IF;
  ELSE
    v_counts := v_counts || jsonb_build_object(
      'pickup_game_requests_withdrawn', 0,
      'pickup_game_requests_cancelled_for_created_games', 0
    );
  END IF;

  IF to_regclass('public.notifications') IS NOT NULL THEN
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'notifications' AND column_name = 'user_id') THEN
      v_notification_where_clauses := v_notification_where_clauses || ARRAY['user_id = $1'];
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'notifications' AND column_name = 'recipient_user_id') THEN
      v_notification_where_clauses := v_notification_where_clauses || ARRAY['recipient_user_id = $1'];
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'notifications' AND column_name = 'target_user_id') THEN
      v_notification_where_clauses := v_notification_where_clauses || ARRAY['target_user_id = $1'];
    END IF;

    IF array_length(v_notification_where_clauses, 1) IS NOT NULL THEN
      v_sql := format(
        'DELETE FROM public.notifications WHERE %s',
        array_to_string(v_notification_where_clauses, ' OR ')
      );
      EXECUTE v_sql USING v_uid;
      GET DIAGNOSTICS v_count = ROW_COUNT;
      v_counts := v_counts || jsonb_build_object('notifications_deleted', v_count);
    ELSE
      v_counts := v_counts || jsonb_build_object('notifications_deleted', 0);
    END IF;
  ELSE
    v_counts := v_counts || jsonb_build_object('notifications_deleted', 0);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'deleted_user_id', v_uid,
    'normalized_email', v_email,
    'affected_counts', v_counts,
    'avatar_storage_paths', to_jsonb(coalesce(v_avatar_storage_paths, ARRAY[]::text[]))
  );
END;
$$;

COMMENT ON FUNCTION public.request_delete_my_account() IS
  'Authenticated fan self-service account deletion Phase 1. Soft-deletes/anonymizes user_profiles, removes personal preference/activity signals, preserves direct messages, Fan Chat threads, reports, moderation records, and auth.users. Returns exact avatar storage paths for best-effort cleanup after commit.';

REVOKE ALL ON FUNCTION public.request_delete_my_account() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.request_delete_my_account() TO authenticated;
