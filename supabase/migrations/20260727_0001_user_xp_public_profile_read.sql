-- Allow authenticated fans to read others' Fan Level summary for public profile previews (no email exposure).

DROP POLICY IF EXISTS user_xp_select_public_profile ON public.user_xp;
CREATE POLICY user_xp_select_public_profile
  ON public.user_xp FOR SELECT TO authenticated
  USING (true);

COMMENT ON POLICY user_xp_select_public_profile ON public.user_xp IS
  'Authenticated users can read Fan Level/XP summary for public profile cards (display_name/handle/avatar remain on user_profiles).';
