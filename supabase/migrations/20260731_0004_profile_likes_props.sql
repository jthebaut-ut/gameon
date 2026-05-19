-- Fan Props backend foundation.
-- Database name intentionally stays profile_likes; user-facing app copy should say Props / Fan Props.

CREATE TABLE IF NOT EXISTS public.profile_likes (
  liker_user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  liked_user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  source text,
  PRIMARY KEY (liker_user_id, liked_user_id),
  CONSTRAINT profile_likes_no_self_like CHECK (liker_user_id <> liked_user_id)
);

CREATE INDEX IF NOT EXISTS idx_profile_likes_liked_created
  ON public.profile_likes (liked_user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_profile_likes_liker_created
  ON public.profile_likes (liker_user_id, created_at DESC);

ALTER TABLE public.profile_likes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS profile_likes_insert_own_unblocked ON public.profile_likes;
CREATE POLICY profile_likes_insert_own_unblocked
  ON public.profile_likes FOR INSERT TO authenticated
  WITH CHECK (
    liker_user_id = auth.uid()
    AND NOT EXISTS (
      SELECT 1
      FROM public.blocked_users b
      WHERE (b.blocker_user_id = liker_user_id AND b.blocked_user_id = liked_user_id)
         OR (b.blocker_user_id = liked_user_id AND b.blocked_user_id = liker_user_id)
    )
  );

DROP POLICY IF EXISTS profile_likes_delete_own ON public.profile_likes;
CREATE POLICY profile_likes_delete_own
  ON public.profile_likes FOR DELETE TO authenticated
  USING (liker_user_id = auth.uid());

DROP POLICY IF EXISTS profile_likes_select_own_outgoing_unblocked ON public.profile_likes;
CREATE POLICY profile_likes_select_own_outgoing_unblocked
  ON public.profile_likes FOR SELECT TO authenticated
  USING (
    liker_user_id = auth.uid()
    AND NOT EXISTS (
      SELECT 1
      FROM public.blocked_users b
      WHERE (b.blocker_user_id = liker_user_id AND b.blocked_user_id = liked_user_id)
         OR (b.blocker_user_id = liked_user_id AND b.blocked_user_id = liker_user_id)
    )
  );

DROP POLICY IF EXISTS profile_likes_select_own_incoming_unblocked ON public.profile_likes;
CREATE POLICY profile_likes_select_own_incoming_unblocked
  ON public.profile_likes FOR SELECT TO authenticated
  USING (
    liked_user_id = auth.uid()
    AND NOT EXISTS (
      SELECT 1
      FROM public.blocked_users b
      WHERE (b.blocker_user_id = liker_user_id AND b.blocked_user_id = liked_user_id)
         OR (b.blocker_user_id = liked_user_id AND b.blocked_user_id = liker_user_id)
    )
  );

GRANT SELECT, INSERT, DELETE ON public.profile_likes TO authenticated;

COMMENT ON TABLE public.profile_likes IS
  'Fan Props between user profiles. Full liked-by lists are only visible to involved authenticated users.';

COMMENT ON COLUMN public.profile_likes.source IS
  'Optional origin for the Fan Props action, such as profile or search.';
