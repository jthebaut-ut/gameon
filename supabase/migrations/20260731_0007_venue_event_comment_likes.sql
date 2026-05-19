CREATE TABLE IF NOT EXISTS public.venue_event_comment_likes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  comment_id uuid NOT NULL,
  user_id uuid NOT NULL REFERENCES public.user_profiles (id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT venue_event_comment_likes_comment_user_unique UNIQUE (comment_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_venue_event_comment_likes_comment_id
  ON public.venue_event_comment_likes (comment_id);

CREATE INDEX IF NOT EXISTS idx_venue_event_comment_likes_user_id
  ON public.venue_event_comment_likes (user_id);

ALTER TABLE public.venue_event_comment_likes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS venue_event_comment_likes_insert_own ON public.venue_event_comment_likes;
CREATE POLICY venue_event_comment_likes_insert_own
  ON public.venue_event_comment_likes FOR INSERT TO authenticated
  WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS venue_event_comment_likes_delete_own ON public.venue_event_comment_likes;
CREATE POLICY venue_event_comment_likes_delete_own
  ON public.venue_event_comment_likes FOR DELETE TO authenticated
  USING (user_id = auth.uid());

DROP POLICY IF EXISTS venue_event_comment_likes_select_own ON public.venue_event_comment_likes;
CREATE POLICY venue_event_comment_likes_select_own
  ON public.venue_event_comment_likes FOR SELECT TO authenticated
  USING (user_id = auth.uid());

DROP POLICY IF EXISTS venue_event_comment_likes_select_authenticated ON public.venue_event_comment_likes;
CREATE POLICY venue_event_comment_likes_select_authenticated
  ON public.venue_event_comment_likes FOR SELECT TO authenticated
  USING (true);

GRANT SELECT, INSERT, DELETE ON public.venue_event_comment_likes TO authenticated;
