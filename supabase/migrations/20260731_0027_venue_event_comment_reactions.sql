-- Fan Chat comment reactions: migrate legacy heart likes to thumbs up / thumbs down.
-- The legacy venue_event_comment_likes table is intentionally retained for rollback
-- and for older clients during the transition.

CREATE TABLE IF NOT EXISTS public.venue_event_comment_reactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  comment_id uuid NOT NULL REFERENCES public.venue_event_comments (id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  reaction_type text NOT NULL CHECK (reaction_type IN ('up', 'down')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT venue_event_comment_reactions_comment_user_unique UNIQUE (comment_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_venue_event_comment_reactions_comment_id
  ON public.venue_event_comment_reactions (comment_id);

CREATE INDEX IF NOT EXISTS idx_venue_event_comment_reactions_user_id
  ON public.venue_event_comment_reactions (user_id);

CREATE INDEX IF NOT EXISTS idx_venue_event_comment_reactions_comment_type
  ON public.venue_event_comment_reactions (comment_id, reaction_type);

CREATE OR REPLACE FUNCTION public.touch_venue_event_comment_reaction_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS venue_event_comment_reactions_touch_updated_at
  ON public.venue_event_comment_reactions;

CREATE TRIGGER venue_event_comment_reactions_touch_updated_at
  BEFORE UPDATE ON public.venue_event_comment_reactions
  FOR EACH ROW
  EXECUTE FUNCTION public.touch_venue_event_comment_reaction_updated_at();

DO $$
DECLARE
  legacy_count bigint := 0;
  inserted_count bigint := 0;
BEGIN
  IF to_regclass('public.venue_event_comment_likes') IS NOT NULL THEN
    SELECT count(*)
    INTO legacy_count
    FROM public.venue_event_comment_likes;

    INSERT INTO public.venue_event_comment_reactions (
      comment_id,
      user_id,
      reaction_type,
      created_at,
      updated_at
    )
    SELECT
      l.comment_id,
      l.user_id,
      'up',
      COALESCE(l.created_at, now()),
      COALESCE(l.created_at, now())
    FROM public.venue_event_comment_likes l
    JOIN public.venue_event_comments c ON c.id = l.comment_id
    ON CONFLICT (comment_id, user_id) DO UPDATE
      SET reaction_type = 'up',
          updated_at = EXCLUDED.updated_at;

    GET DIAGNOSTICS inserted_count = ROW_COUNT;
    RAISE NOTICE '[FanChatReactionDebug] legacyLikesMigrated=% source_count=% affected_count=%',
      true,
      legacy_count,
      inserted_count;
  ELSE
    RAISE NOTICE '[FanChatReactionDebug] legacyLikesMigrated=% source_count=% affected_count=%',
      false,
      0,
      0;
  END IF;
END $$;

ALTER TABLE public.venue_event_comment_reactions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS venue_event_comment_reactions_select_visible_comments
  ON public.venue_event_comment_reactions;
CREATE POLICY venue_event_comment_reactions_select_visible_comments
  ON public.venue_event_comment_reactions FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.venue_event_comments c
      WHERE c.id = venue_event_comment_reactions.comment_id
        AND COALESCE(c.is_moderation_hidden, false) = false
    )
  );

DROP POLICY IF EXISTS venue_event_comment_reactions_insert_own_visible_comment
  ON public.venue_event_comment_reactions;
CREATE POLICY venue_event_comment_reactions_insert_own_visible_comment
  ON public.venue_event_comment_reactions FOR INSERT TO authenticated
  WITH CHECK (
    user_id = auth.uid()
    AND reaction_type IN ('up', 'down')
    AND EXISTS (
      SELECT 1
      FROM public.venue_event_comments c
      WHERE c.id = venue_event_comment_reactions.comment_id
        AND COALESCE(c.is_moderation_hidden, false) = false
    )
  );

DROP POLICY IF EXISTS venue_event_comment_reactions_update_own_visible_comment
  ON public.venue_event_comment_reactions;
CREATE POLICY venue_event_comment_reactions_update_own_visible_comment
  ON public.venue_event_comment_reactions FOR UPDATE TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (
    user_id = auth.uid()
    AND reaction_type IN ('up', 'down')
    AND EXISTS (
      SELECT 1
      FROM public.venue_event_comments c
      WHERE c.id = venue_event_comment_reactions.comment_id
        AND COALESCE(c.is_moderation_hidden, false) = false
    )
  );

DROP POLICY IF EXISTS venue_event_comment_reactions_delete_own
  ON public.venue_event_comment_reactions;
CREATE POLICY venue_event_comment_reactions_delete_own
  ON public.venue_event_comment_reactions FOR DELETE TO authenticated
  USING (user_id = auth.uid());

GRANT SELECT, INSERT, UPDATE, DELETE ON public.venue_event_comment_reactions TO authenticated;

COMMENT ON TABLE public.venue_event_comment_reactions IS
  'Fan Chat comment reactions. One up/down reaction per authenticated user per venue event comment.';
