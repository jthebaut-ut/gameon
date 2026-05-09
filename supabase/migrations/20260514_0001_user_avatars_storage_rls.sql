-- user-avatars: align Storage RLS with app paths `user-avatars/{auth.uid()}/avatar.jpg` (and *_thumb).
-- App uploads use the authenticated Supabase Auth user id as the first folder segment (lowercase UUID string).

-- Read: public bucket objects are readable without auth (public URLs / AsyncImage).
DROP POLICY IF EXISTS "user_avatars_select_public" ON storage.objects;
CREATE POLICY "user_avatars_select_public"
  ON storage.objects FOR SELECT
  TO public
  USING (bucket_id = 'user-avatars');

-- Write: only the signed-in user may insert/update/delete under their uid folder.
DROP POLICY IF EXISTS "user_avatars_insert_own" ON storage.objects;
CREATE POLICY "user_avatars_insert_own"
  ON storage.objects FOR INSERT
  TO authenticated
  WITH CHECK (
    bucket_id = 'user-avatars'
    AND split_part(name, '/', 1) = auth.uid()::text
  );

DROP POLICY IF EXISTS "user_avatars_update_own" ON storage.objects;
CREATE POLICY "user_avatars_update_own"
  ON storage.objects FOR UPDATE
  TO authenticated
  USING (
    bucket_id = 'user-avatars'
    AND split_part(name, '/', 1) = auth.uid()::text
  )
  WITH CHECK (
    bucket_id = 'user-avatars'
    AND split_part(name, '/', 1) = auth.uid()::text
  );

DROP POLICY IF EXISTS "user_avatars_delete_own" ON storage.objects;
CREATE POLICY "user_avatars_delete_own"
  ON storage.objects FOR DELETE
  TO authenticated
  USING (
    bucket_id = 'user-avatars'
    AND split_part(name, '/', 1) = auth.uid()::text
  );
