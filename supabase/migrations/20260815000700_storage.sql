-- ============================================================================
-- 0700 — Storage buckets + policies
-- ============================================================================
-- Two buckets, both public-read (matching the "everything is public" model) and
-- both write-restricted to a folder named after the uploader's UID.
--
-- The UID-prefixed path is the entire write-authorization scheme:
--   visit-photos/{user_id}/{visit_id}/{uuid}.jpg
--   avatars/{user_id}/avatar.jpg
-- storage.foldername(name)[1] is that first path segment, and every write policy
-- below asserts it equals auth.uid(). Get the path shape wrong in the client and
-- the upload is rejected — which is the intended failure mode.
--
-- If these statements fail with "must be owner of table objects", your SQL role
-- lacks ownership of storage.objects. Running migrations with `supabase db push`
-- (or as `postgres` in the dashboard SQL editor) has the required privileges;
-- otherwise create the two buckets and their policies in
-- Dashboard -> Storage -> Policies by hand.
-- ============================================================================

set search_path = public, extensions;

-- ----------------------------------------------------------------------------
-- Buckets
-- ----------------------------------------------------------------------------
-- Limits, and why:
--   visit-photos — 10 MB. A 12MP HEIC off an iPhone is ~2-4 MB and a full-res
--     JPEG export ~5-8 MB, so 10 MB accepts real photos while rejecting video
--     files renamed to .jpg and accidental ProRAW uploads.
--   avatars — 2 MB. An avatar is displayed at ~68pt; anything above 2 MB is a
--     client-side resize bug, not a legitimate upload.
--
-- HEIC/HEIF are allowed because that is the iPhone camera default and forcing a
-- JPEG transcode on device costs time and quality. The app currently uploads
-- JPEG; the extra MIME types mean switching later needs no migration.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'visit-photos',
  'visit-photos',
  true,
  10485760,   -- 10 MB
  array['image/jpeg', 'image/png', 'image/heic', 'image/heif', 'image/webp']
)
on conflict (id) do update set
  public             = excluded.public,
  file_size_limit    = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'avatars',
  'avatars',
  true,
  2097152,    -- 2 MB
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do update set
  public             = excluded.public,
  file_size_limit    = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;


-- ----------------------------------------------------------------------------
-- visit-photos policies
-- ----------------------------------------------------------------------------

-- READ: public. Both buckets are marked public, so the CDN endpoint serves them
-- without consulting RLS anyway; this policy makes the API path agree with the
-- CDN path instead of silently diverging.
drop policy if exists "visit_photos_public_read" on storage.objects;
create policy "visit_photos_public_read"
  on storage.objects for select
  to public
  using (bucket_id = 'visit-photos');

-- WRITE: only into your own UID folder.
drop policy if exists "visit_photos_insert_own_folder" on storage.objects;
create policy "visit_photos_insert_own_folder"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'visit-photos'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- UPDATE (overwrite/upsert): same folder rule on both sides, so an object cannot
-- be moved out of your folder by an update.
drop policy if exists "visit_photos_update_own_folder" on storage.objects;
create policy "visit_photos_update_own_folder"
  on storage.objects for update
  to authenticated
  using (
    bucket_id = 'visit-photos'
    and (storage.foldername(name))[1] = auth.uid()::text
  )
  with check (
    bucket_id = 'visit-photos'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "visit_photos_delete_own_folder" on storage.objects;
create policy "visit_photos_delete_own_folder"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'visit-photos'
    and (storage.foldername(name))[1] = auth.uid()::text
  );


-- ----------------------------------------------------------------------------
-- avatars policies
-- ----------------------------------------------------------------------------

drop policy if exists "avatars_public_read" on storage.objects;
create policy "avatars_public_read"
  on storage.objects for select
  to public
  using (bucket_id = 'avatars');

drop policy if exists "avatars_insert_own_folder" on storage.objects;
create policy "avatars_insert_own_folder"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- Avatars are written with upsert (the path is always {uid}/avatar.jpg), so the
-- UPDATE policy is not optional — without it the second avatar change fails.
drop policy if exists "avatars_update_own_folder" on storage.objects;
create policy "avatars_update_own_folder"
  on storage.objects for update
  to authenticated
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  )
  with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "avatars_delete_own_folder" on storage.objects;
create policy "avatars_delete_own_folder"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
