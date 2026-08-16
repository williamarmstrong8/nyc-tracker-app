-- ============================================================================
-- 0600 — Row Level Security
-- ============================================================================
-- READ THIS BEFORE ASSUMING THERE IS A BUG HERE.
--
-- This app is public by design. Every visit, photo, transcript, AI summary and
-- wishlist item is readable by ANY authenticated user. There is no per-visit
-- privacy setting and there is not meant to be one. The friend graph decides
-- what gets SHOWN on your map and in your feed; it never decides what you are
-- ALLOWED to read. If a future feature needs private visits, that is a schema
-- change (a visibility column) plus a rewrite of these policies — not something
-- to bolt on by filtering in the client.
--
-- Consequence: the read policies below look suspiciously permissive. They are
-- correct. The interesting policies are the WRITE ones.
--
-- The one exception is `recommendations`, which is genuinely private to the two
-- people involved.
--
-- All policies target the `authenticated` role. `anon` gets no policy anywhere,
-- so an unauthenticated key can read nothing — which matches the app's hard auth
-- gate (no guest mode).
-- ============================================================================

set search_path = public, extensions;

alter table public.profiles         enable row level security;
alter table public.places           enable row level security;
alter table public.visits           enable row level security;
alter table public.visit_photos     enable row level security;
alter table public.friendships      enable row level security;
alter table public.recommendations  enable row level security;
alter table public.wishlist_items   enable row level security;


-- ============================================================================
-- profiles
-- ============================================================================

-- READ: any signed-in user can see any profile. Required for friend search,
-- feed author bylines, and "3 friends have been here" avatars.
drop policy if exists profiles_select_authenticated on public.profiles;
create policy profiles_select_authenticated
  on public.profiles for select
  to authenticated
  using (true);

-- INSERT: nobody. Rows are created exclusively by the handle_new_user() trigger
-- on auth.users. A client that could insert here could forge a profile for
-- another auth user id.
--   (Absence of an INSERT policy = insert denied. Stated explicitly for readers.)

-- UPDATE: own row only, and you cannot move a row to another id.
drop policy if exists profiles_update_own on public.profiles;
create policy profiles_update_own
  on public.profiles for update
  to authenticated
  using (auth.uid() = id)
  with check (auth.uid() = id);

-- DELETE: nobody. Account deletion goes through the delete-account Edge
-- Function, which removes the auth.users row and lets the cascade clean up.


-- ============================================================================
-- places
-- ============================================================================

-- READ: any signed-in user. Places are shared, canonical, and contain no
-- personal data — just venue facts.
drop policy if exists places_select_authenticated on public.places;
create policy places_select_authenticated
  on public.places for select
  to authenticated
  using (true);

-- INSERT / UPDATE / DELETE: no policies at all, on purpose.
--
-- All writes go through find_or_create_place(), which is SECURITY DEFINER and
-- therefore bypasses RLS. This is what keeps the dedupe invariant enforceable:
-- if clients could INSERT directly they would race each other and create
-- duplicate venues, and the "backfill nulls, never overwrite" rule would be
-- unenforceable. One write path, one set of rules.


-- ============================================================================
-- visits
-- ============================================================================

-- READ: any signed-in user — see the header. This is the "everything is public"
-- rule in its most consequential form: your transcripts and summaries are
-- readable by every user of the app, not just your friends.
drop policy if exists visits_select_authenticated on public.visits;
create policy visits_select_authenticated
  on public.visits for select
  to authenticated
  using (true);

-- INSERT: only for yourself. Stops a client from attributing a visit to someone
-- else's profile.
drop policy if exists visits_insert_own on public.visits;
create policy visits_insert_own
  on public.visits for insert
  to authenticated
  with check (auth.uid() = user_id);

-- UPDATE: own rows only, and the row must still belong to you afterwards (the
-- WITH CHECK blocks re-assigning user_id to another user).
drop policy if exists visits_update_own on public.visits;
create policy visits_update_own
  on public.visits for update
  to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

-- DELETE: own rows only.
drop policy if exists visits_delete_own on public.visits;
create policy visits_delete_own
  on public.visits for delete
  to authenticated
  using (auth.uid() = user_id);


-- ============================================================================
-- visit_photos
-- ============================================================================
-- Photos have no user_id of their own; ownership is inherited from the parent
-- visit, so every write policy is an EXISTS against visits.

-- READ: any signed-in user, matching visits.
drop policy if exists visit_photos_select_authenticated on public.visit_photos;
create policy visit_photos_select_authenticated
  on public.visit_photos for select
  to authenticated
  using (true);

-- INSERT: only onto a visit you own.
drop policy if exists visit_photos_insert_own on public.visit_photos;
create policy visit_photos_insert_own
  on public.visit_photos for insert
  to authenticated
  with check (
    exists (
      select 1 from public.visits v
      where v.id = visit_photos.visit_id
        and v.user_id = auth.uid()
    )
  );

-- UPDATE: only on a visit you own, and it must still be your visit afterwards
-- (WITH CHECK blocks re-parenting a photo onto someone else's visit).
drop policy if exists visit_photos_update_own on public.visit_photos;
create policy visit_photos_update_own
  on public.visit_photos for update
  to authenticated
  using (
    exists (
      select 1 from public.visits v
      where v.id = visit_photos.visit_id
        and v.user_id = auth.uid()
    )
  )
  with check (
    exists (
      select 1 from public.visits v
      where v.id = visit_photos.visit_id
        and v.user_id = auth.uid()
    )
  );

-- DELETE: only from a visit you own.
drop policy if exists visit_photos_delete_own on public.visit_photos;
create policy visit_photos_delete_own
  on public.visit_photos for delete
  to authenticated
  using (
    exists (
      select 1 from public.visits v
      where v.id = visit_photos.visit_id
        and v.user_id = auth.uid()
    )
  );


-- ============================================================================
-- wishlist_items
-- ============================================================================

-- READ: any signed-in user. Deliberate: "places Sam wants to try" is a feature,
-- not a leak — it's how you find somewhere to go together.
drop policy if exists wishlist_select_authenticated on public.wishlist_items;
create policy wishlist_select_authenticated
  on public.wishlist_items for select
  to authenticated
  using (true);

drop policy if exists wishlist_insert_own on public.wishlist_items;
create policy wishlist_insert_own
  on public.wishlist_items for insert
  to authenticated
  with check (auth.uid() = user_id);

drop policy if exists wishlist_update_own on public.wishlist_items;
create policy wishlist_update_own
  on public.wishlist_items for update
  to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

drop policy if exists wishlist_delete_own on public.wishlist_items;
create policy wishlist_delete_own
  on public.wishlist_items for delete
  to authenticated
  using (auth.uid() = user_id);


-- ============================================================================
-- friendships
-- ============================================================================

-- READ: accepted rows are public (that's what makes "mutual friends" and friend
-- counts possible), but pending and blocked rows are visible only to the two
-- parties. Nobody else needs to know you were declined or that someone blocked
-- someone.
drop policy if exists friendships_select_visible on public.friendships;
create policy friendships_select_visible
  on public.friendships for select
  to authenticated
  using (
    status = 'accepted'
    or auth.uid() = requester_id
    or auth.uid() = addressee_id
  );

-- INSERT: you may only create a request FROM yourself, and only as 'pending'.
-- Without the status clause a client could insert a row already marked
-- 'accepted' and friend itself to anyone.
drop policy if exists friendships_insert_as_requester on public.friendships;
create policy friendships_insert_as_requester
  on public.friendships for insert
  to authenticated
  with check (
    auth.uid() = requester_id
    and status = 'pending'
  );

-- UPDATE (accept): only the addressee, only pending -> accepted. The requester
-- cannot accept their own request; that's the entire point of a request.
drop policy if exists friendships_accept_by_addressee on public.friendships;
create policy friendships_accept_by_addressee
  on public.friendships for update
  to authenticated
  using (auth.uid() = addressee_id and status = 'pending')
  with check (auth.uid() = addressee_id and status = 'accepted');

-- UPDATE (block): either party may move any row to 'blocked'. Not in the
-- original spec, but 'blocked' is a valid status in the CHECK constraint and
-- would otherwise be unreachable from the client. Unblocking is a DELETE.
drop policy if exists friendships_block_by_party on public.friendships;
create policy friendships_block_by_party
  on public.friendships for update
  to authenticated
  using (auth.uid() in (requester_id, addressee_id))
  with check (auth.uid() in (requester_id, addressee_id) and status = 'blocked');

-- DELETE: either party, any status. Covers cancelling your own request,
-- declining an incoming one, unfriending, and unblocking — all the same
-- operation on a mutual graph.
drop policy if exists friendships_delete_by_party on public.friendships;
create policy friendships_delete_by_party
  on public.friendships for delete
  to authenticated
  using (auth.uid() in (requester_id, addressee_id));


-- ============================================================================
-- recommendations  — the one genuinely private table
-- ============================================================================

-- READ: sender and recipient only. A recommendation carries a personal message
-- and reveals who is talking to whom; neither belongs in the public read model.
drop policy if exists recommendations_select_parties on public.recommendations;
create policy recommendations_select_parties
  on public.recommendations for select
  to authenticated
  using (auth.uid() in (sender_id, recipient_id));

-- INSERT: only as yourself. You cannot send a recommendation "from" someone else.
drop policy if exists recommendations_insert_as_sender on public.recommendations;
create policy recommendations_insert_as_sender
  on public.recommendations for insert
  to authenticated
  with check (auth.uid() = sender_id);

-- UPDATE: recipient only.
--
-- The spec is "recipient can update ONLY the status field". RLS cannot express
-- column-level restrictions — a policy is row-scoped — so the column limit is
-- enforced with a column-level GRANT below. Both are required: the GRANT says
-- WHICH columns, the policy says WHICH rows.
drop policy if exists recommendations_update_by_recipient on public.recommendations;
create policy recommendations_update_by_recipient
  on public.recommendations for update
  to authenticated
  using (auth.uid() = recipient_id)
  with check (auth.uid() = recipient_id);

-- DELETE: sender may withdraw. (Recipients dismiss via status rather than
-- deleting, so the unique constraint keeps working as an anti-spam guard.)
drop policy if exists recommendations_delete_by_sender on public.recommendations;
create policy recommendations_delete_by_sender
  on public.recommendations for delete
  to authenticated
  using (auth.uid() = sender_id);

-- Column-level privileges for the update rule above.
-- Supabase grants ALL on new public tables to `authenticated` by default, so a
-- table-wide UPDATE grant already exists and must be revoked before the narrow
-- one takes effect.
revoke update on public.recommendations from authenticated;
grant  update (status, read_at) on public.recommendations to authenticated;

-- `anon` should not be able to touch any of this. RLS already denies it (no
-- policy names the anon role), but revoking the grants means a mistake in a
-- future policy can't accidentally open it up.
revoke all on public.profiles        from anon;
revoke all on public.places          from anon;
revoke all on public.visits          from anon;
revoke all on public.visit_photos    from anon;
revoke all on public.friendships     from anon;
revoke all on public.recommendations from anon;
revoke all on public.wishlist_items  from anon;
