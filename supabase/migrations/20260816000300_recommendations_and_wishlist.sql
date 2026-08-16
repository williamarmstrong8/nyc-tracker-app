-- ============================================================================
-- 0816.0300 — Recommendations, wishlist, explore feed, social stats
-- ============================================================================
-- The last of the four core migrations. `recommendations` and `wishlist_items`
-- were created speculatively in 0500_social.sql; this is the first code to read
-- or write either, so it is also their audit.
--
-- Three decisions here are load-bearing and are argued where they are made:
--
--   1. Wishlist resolution is a TRIGGER on `visits`, not client code. A visit can
--      arrive from the capture flow, from a sync pull on a second device, or
--      from a future web client, and only one of those is Swift.
--
--   2. `recommend_place()` does the recommendation insert AND the conditional
--      wishlist insert for every recipient in one function. Sequential client
--      calls produce half-sent state — an inbox row with no wishlist item, or
--      the reverse — and the failure is invisible until someone reports it.
--
--   3. "N people recommend this" is derived by COUNTING `recommendations` rows,
--      not by adding a counter column to `wishlist_items`. See the note on
--      `wishlist_entries()`.
--
-- All statements are idempotent.
-- ============================================================================

set search_path = public, extensions;


-- ----------------------------------------------------------------------------
-- 1. Wishlist resolution — a trigger on visits
-- ----------------------------------------------------------------------------
-- "Wanted to go -> went" is the whole arc of the recommendation feature, and it
-- has to close itself. In the client it would live in the capture flow, which
-- is one of at least three ways a visit can appear: capture, a sync pull on
-- another device, and whatever writes visits next. A trigger covers all of them
-- and cannot be forgotten by a new code path.
--
-- SECURITY DEFINER, but scoped: the UPDATE below can only ever touch rows whose
-- `user_id` equals the visit's own `user_id`. It is definer so that a visit
-- written by any path resolves the wishlist, rather than depending on the
-- writer's role happening to satisfy `wishlist_update_own`.
--
-- Fires on UPDATE as well as INSERT, for two paths the brief's "on insert"
-- wording doesn't cover:
--   * "Mark as visited" on a want-to-try flips `kind`, which is an UPDATE.
--   * The sync engine upserts, so a visit created offline first reaches Postgres
--     as an INSERT but a later edit arrives as an UPDATE.
-- The `resolved_visit_id is null` guard makes re-firing a no-op, so upserts that
-- touch a row repeatedly cost one indexed lookup and change nothing.
create or replace function public.wishlist_resolve_on_visit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Soft-deleting a visit un-resolves anything it resolved. Otherwise the
  -- wishlist keeps claiming you went somewhere on the strength of an entry you
  -- deleted, and the item can never resolve again because it already looks done.
  -- (`wishlist_stamp_resolved` clears `resolved_at` when the id goes null.)
  if new.deleted_at is not null then
    update public.wishlist_items w
       set resolved_visit_id = null
     where w.resolved_visit_id = new.id;
    return new;
  end if;

  -- A want-to-try is an intention, not a visit. Resolving on one would mark the
  -- wishlist item done the moment the user bookmarked the place.
  if new.kind <> 'visited' then
    return new;
  end if;

  update public.wishlist_items w
     set resolved_visit_id = new.id
   where w.user_id  = new.user_id
     and w.place_id = new.place_id
     and w.resolved_visit_id is null;

  return new;
end;
$$;

drop trigger if exists visits_resolve_wishlist_trg on public.visits;
create trigger visits_resolve_wishlist_trg
  after insert or update on public.visits
  for each row execute function public.wishlist_resolve_on_visit();

comment on function public.wishlist_resolve_on_visit() is
  'Closes the loop: logging a visit resolves any matching unresolved wishlist item. Soft-deleting the visit un-resolves it.';

-- Query the trigger runs on every visit write: (user_id, place_id) restricted to
-- unresolved rows. The existing `wishlist_items_active_idx` is on (user_id) only
-- with the same partial predicate; adding place_id makes this an index-only
-- match rather than a scan of everything the user still wants to try.
create index if not exists wishlist_items_user_place_active_idx
  on public.wishlist_items (user_id, place_id)
  where resolved_visit_id is null;

-- Query: "did this visit resolve anything" on the un-resolve path above.
create index if not exists wishlist_items_resolved_visit_idx
  on public.wishlist_items (resolved_visit_id)
  where resolved_visit_id is not null;


-- ----------------------------------------------------------------------------
-- 2. recommend_place — the whole send, for every recipient, in one call
-- ----------------------------------------------------------------------------
-- Returns one row per recipient describing what happened, rather than raising.
-- Every "error" case here is a normal thing a person does — sending to someone
-- who already has it, re-sending, sending somewhere they've already been — and
-- an exception would abort the other recipients in the same batch.
--
-- Outcomes:
--   sent            new recommendation; wishlist item created if there wasn't one
--   already_sent    (sender, recipient, place) already exists — the unique
--                   constraint doing its anti-spam job. Not an error.
--   already_visited recipient has logged a visit here. Still sent; the wishlist
--                   item is inserted PRE-RESOLVED against that visit.
--   not_friends     recipient isn't an accepted friend
--   self            recipient is the sender
--
-- ## Why "already visited" inserts pre-resolved rather than skipping
--
-- Both options keep the inbox item, so the sender's gesture survives either way.
-- The difference is what the recipient's wishlist remembers. Skipping the insert
-- loses the fact that someone recommended it entirely — the recommendation lives
-- only in the inbox, and once dismissed there is no record that Sam thought of
-- you when they saw this place. Inserting pre-resolved records the same arc the
-- trigger above produces naturally ("someone suggested it, I'd been"), lands in
-- the "been there" section instead of the active list, and needs no special case
-- in any read path. It costs one row.
--
-- SECURITY INVOKER: the insert is `auth.uid() = sender_id`, which
-- `recommendations_insert_as_sender` already enforces. Note the deliberate
-- asymmetry — the WISHLIST insert writes a row owned by the RECIPIENT, which
-- `wishlist_insert_own` forbids. That is why this one function is split: see
-- `wishlist_insert_for_recipient` below.
create or replace function public.recommend_place(
  p_place      uuid,
  p_recipients uuid[],
  p_message    text default null
)
returns table (
  recipient_id      uuid,
  outcome           text,
  recommendation_id uuid
)
language plpgsql
security invoker
set search_path = public, extensions
as $$
declare
  v_me        uuid := auth.uid();
  v_recipient uuid;
  v_message   text := nullif(btrim(coalesce(p_message, '')), '');
  v_rec_id    uuid;
  v_visit_id  uuid;
  v_outcome   text;
begin
  if v_me is null then
    raise exception 'recommend_place: authentication required' using errcode = '28000';
  end if;

  if p_place is null then
    raise exception 'recommend_place: place is required' using errcode = '22023';
  end if;

  if not exists (select 1 from public.places pl where pl.id = p_place) then
    raise exception 'recommend_place: no such place' using errcode = '23503';
  end if;

  foreach v_recipient in array coalesce(p_recipients, '{}'::uuid[])
  loop
    v_rec_id   := null;
    v_visit_id := null;

    if v_recipient = v_me then
      recipient_id := v_recipient; outcome := 'self'; recommendation_id := null;
      return next;
      continue;
    end if;

    -- Friends-only. The picker only offers friends, but the constraint belongs
    -- here too: `recommendations` is the one table a stranger could otherwise
    -- write into someone's private inbox.
    if not public.are_friends(v_me, v_recipient) then
      recipient_id := v_recipient; outcome := 'not_friends'; recommendation_id := null;
      return next;
      continue;
    end if;

    -- Has the recipient already been here? Read before the insert so the
    -- wishlist row can be created pre-resolved in one statement.
    select v.id
      into v_visit_id
      from public.visits v
     where v.user_id    = v_recipient
       and v.place_id   = p_place
       and v.kind       = 'visited'
       and v.deleted_at is null
     order by v.visited_at desc
     limit 1;

    insert into public.recommendations (sender_id, recipient_id, place_id, message)
    values (v_me, v_recipient, p_place, v_message)
    on conflict (sender_id, recipient_id, place_id) do nothing
    returning id into v_rec_id;

    if v_rec_id is null then
      -- The unique constraint fired: we already sent this person this place.
      -- Hand back the existing row so the client can say "already sent" and
      -- still link to it.
      select r.id
        into v_rec_id
        from public.recommendations r
       where r.sender_id    = v_me
         and r.recipient_id = v_recipient
         and r.place_id     = p_place;

      recipient_id := v_recipient; outcome := 'already_sent'; recommendation_id := v_rec_id;
      return next;
      continue;
    end if;

    -- New recommendation. Give the recipient a wishlist item unless they already
    -- have one — in which case theirs keeps its original provenance, and the
    -- "N people recommend this" count comes from the recommendations rows.
    perform public.wishlist_insert_for_recipient(
      v_recipient, p_place, v_rec_id, v_visit_id
    );

    v_outcome := case when v_visit_id is null then 'sent' else 'already_visited' end;
    recipient_id := v_recipient; outcome := v_outcome; recommendation_id := v_rec_id;
    return next;
  end loop;

  return;
end;
$$;

-- ----------------------------------------------------------------------------
-- wishlist_insert_for_recipient — the one genuinely privileged step
-- ----------------------------------------------------------------------------
-- Writing a wishlist row for SOMEONE ELSE is the only thing in this whole
-- feature that RLS cannot express. `wishlist_insert_own` requires
-- `auth.uid() = user_id`, and correctly so — otherwise anyone could stuff
-- anyone's wishlist. But a recommendation is exactly "put this on your list",
-- so the capability has to exist somewhere.
--
-- Isolated into its own SECURITY DEFINER function, deliberately small, rather
-- than making `recommend_place` definer. That function does friend checks,
-- visit lookups and inserts into a private table; running all of it with RLS
-- bypassed means every future edit to it is a potential privilege bug. This one
-- does a single INSERT with a fixed shape, and the only way to reach it is
-- through a caller that has already proved the two users are friends.
--
-- It is NOT granted to `authenticated`. Only `recommend_place` calls it, and
-- that call runs with the definer's rights regardless of the caller's grants.
create or replace function public.wishlist_insert_for_recipient(
  p_user              uuid,
  p_place             uuid,
  p_recommendation_id uuid,
  p_resolved_visit_id uuid
)
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.wishlist_items (
    user_id, place_id, source, source_recommendation_id, resolved_visit_id
  )
  values (
    p_user, p_place, 'recommendation', p_recommendation_id, p_resolved_visit_id
  )
  -- Already on their list: leave it exactly as it is. Overwriting `source` would
  -- rewrite a place they chose themselves into one they were sent.
  on conflict (user_id, place_id) do nothing;
$$;

comment on function public.recommend_place(uuid, uuid[], text) is
  'Sends a place to several friends at once. Returns a per-recipient outcome instead of raising on the duplicate/already-visited cases.';


-- ----------------------------------------------------------------------------
-- 3. Inbox: recommendations
-- ----------------------------------------------------------------------------
-- Dismissed rows are excluded — dismissing is the recipient saying "stop showing
-- me this". The row survives so the unique constraint keeps working as an
-- anti-spam guard, and so the wishlist item keeps its provenance.
create or replace function public.inbox_recommendations()
returns table (
  id              uuid,
  status          text,
  message         text,
  created_at      timestamptz,
  read_at         timestamptz,
  sender_id       uuid,
  username        text,
  display_name    text,
  avatar_url      text,
  place_id        uuid,
  place_name      text,
  place_category  text,
  neighborhood    text,
  street_address  text,
  latitude        double precision,
  longitude       double precision,
  already_visited boolean,
  on_wishlist     boolean
)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select
    r.id,
    r.status,
    r.message,
    r.created_at,
    r.read_at,
    p.id,
    p.username::text,
    p.display_name,
    p.avatar_url,
    pl.id,
    pl.name,
    pl.category,
    pl.neighborhood,
    pl.street_address,
    pl.latitude,
    pl.longitude,
    exists (
      select 1 from public.visits v
      where v.user_id    = r.recipient_id
        and v.place_id   = r.place_id
        and v.kind       = 'visited'
        and v.deleted_at is null
    ),
    exists (
      select 1 from public.wishlist_items w
      where w.user_id  = r.recipient_id
        and w.place_id = r.place_id
    )
  from public.recommendations r
  join public.profiles p on p.id = r.sender_id
  join public.places   pl on pl.id = r.place_id
  where r.recipient_id = auth.uid()
    and r.status <> 'dismissed'
  order by r.created_at desc;
$$;

-- ----------------------------------------------------------------------------
-- mark_recommendations_read — server clock, narrow grant
-- ----------------------------------------------------------------------------
-- `read_at` could be written straight from the client: 0600_rls.sql grants
-- UPDATE on exactly (status, read_at) to the recipient. But then the timestamp
-- is the device's clock, and "read 40 minutes before it was sent" is the kind of
-- thing that shows up much later as an unexplainable sort order. One function,
-- `now()`, done.
--
-- Only touches rows still 'unread', so re-reading an item doesn't keep pushing
-- its timestamp forward.
create or replace function public.mark_recommendations_read(p_ids uuid[])
returns int
language sql
security invoker
set search_path = public, extensions
as $$
  with updated as (
    update public.recommendations r
       set status  = 'read',
           read_at = now()
     where r.id = any(coalesce(p_ids, '{}'::uuid[]))
       and r.recipient_id = auth.uid()
       and r.status = 'unread'
    returning r.id
  )
  select count(*)::int from updated;
$$;


-- ----------------------------------------------------------------------------
-- 4. wishlist_entries — the profile list and the map layer
-- ----------------------------------------------------------------------------
-- ## Why recommender counts are derived, not stored
--
-- The obvious move when a second person recommends the same place is a
-- `recommender_count` column on `wishlist_items`. It would be wrong. The count
-- has to survive the recipient deleting and re-adding the item manually, has to
-- drop when a sender withdraws, and has to name the people ("Sarah and 2
-- others") rather than just count them — all of which the `recommendations`
-- rows already know exactly. A denormalised counter would be a second source of
-- truth that can only ever drift away from the first.
--
-- The aggregate below is over the caller's own recommendations only, which is
-- both the RLS-visible set and the correct one.
create or replace function public.wishlist_entries(p_include_resolved boolean default true)
returns table (
  id                uuid,
  place_id          uuid,
  place_name        text,
  place_category    text,
  neighborhood      text,
  street_address    text,
  latitude          double precision,
  longitude         double precision,
  source            text,
  created_at        timestamptz,
  resolved_visit_id uuid,
  resolved_at       timestamptz,
  recommenders      jsonb
)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select
    w.id,
    pl.id,
    pl.name,
    pl.category,
    pl.neighborhood,
    pl.street_address,
    pl.latitude,
    pl.longitude,
    w.source,
    w.created_at,
    w.resolved_visit_id,
    w.resolved_at,
    coalesce(
      (
        select jsonb_agg(
                 jsonb_build_object(
                   'id',           sp.id,
                   'username',     sp.username::text,
                   'display_name', sp.display_name,
                   'avatar_url',   sp.avatar_url,
                   'message',      r.message,
                   'created_at',   r.created_at
                 )
                 order by r.created_at
               )
        from public.recommendations r
        join public.profiles sp on sp.id = r.sender_id
        where r.recipient_id = w.user_id
          and r.place_id     = w.place_id
      ),
      '[]'::jsonb
    )
  from public.wishlist_items w
  join public.places pl on pl.id = w.place_id
  where w.user_id = auth.uid()
    and (p_include_resolved or w.resolved_visit_id is null)
  order by
    -- Unresolved first: the active list is the point, "been there" is the
    -- archive underneath it.
    (w.resolved_visit_id is not null),
    w.created_at desc;
$$;


-- ----------------------------------------------------------------------------
-- wishlist_add — manual save from a place sheet
-- ----------------------------------------------------------------------------
-- SECURITY INVOKER and writes the caller's own row, so `wishlist_insert_own` is
-- exactly the right check and there is nothing privileged here.
--
-- It exists rather than a plain client INSERT for one reason: ON CONFLICT DO
-- NOTHING. A plain upsert from the client would have to name the conflict target
-- and would then UPDATE the existing row — overwriting `source` to 'manual' and
-- blanking `source_recommendation_id`, which silently erases the fact that a
-- friend suggested the place. Tapping "Save" on somewhere already saved must be
-- a no-op, not a rewrite.
--
-- Returns the row id either way, so the caller can immediately offer "Remove".
create or replace function public.wishlist_add(p_place uuid)
returns uuid
language plpgsql
security invoker
set search_path = public, extensions
as $$
declare
  v_me uuid := auth.uid();
  v_id uuid;
begin
  if v_me is null then
    raise exception 'wishlist_add: authentication required' using errcode = '28000';
  end if;

  insert into public.wishlist_items (user_id, place_id, source)
  values (v_me, p_place, 'manual')
  on conflict (user_id, place_id) do nothing
  returning id into v_id;

  if v_id is null then
    select w.id into v_id
    from public.wishlist_items w
    where w.user_id = v_me and w.place_id = p_place;
  end if;

  return v_id;
end;
$$;


-- ----------------------------------------------------------------------------
-- 5. friend_feed — chronological, keyset-paginated
-- ----------------------------------------------------------------------------
-- Cursor on (visited_at, id), not OFFSET. Friends create visits while the user
-- is scrolling; with OFFSET, a row inserted above the window shifts everything
-- down by one and page 2 repeats the last item of page 1. Keyset asks for "the
-- next rows after this exact position", which is stable under insertion.
--
-- The composite is required because several visits can share a `visited_at` —
-- the capture flow writes a date, and two entries logged the same evening
-- collide often enough to matter. `id` breaks the tie deterministically.
--
-- Row-comparison syntax `(a, b) < (c, d)` is not sugar for
-- `a < c and b < d` — it is lexicographic, which is exactly the ordering the
-- index provides, and Postgres can turn it into a single index range scan.
create or replace function public.friend_feed(
  p_cursor_visited_at timestamptz default null,
  p_cursor_id         uuid        default null,
  p_limit             int         default 20
)
returns table (
  visit_id            uuid,
  visited_at          timestamptz,
  title               text,
  summary             text,
  transcript          text,
  top_quote           text,
  tags                text[],
  rating_label        text,
  return_intent       text,
  kind                text,
  place_id            uuid,
  place_name          text,
  place_category      text,
  neighborhood        text,
  street_address      text,
  latitude            double precision,
  longitude           double precision,
  user_id             uuid,
  username            text,
  display_name        text,
  avatar_url          text,
  photos              jsonb,
  friend_place_count  int
)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  with circle as (
    -- The feed is friends only — deliberately NOT friends + self. Your own
    -- visits are already the entire rest of the app; seeing them again here
    -- makes the one screen that shows other people mostly show you.
    select t.uid from public.friend_ids(auth.uid()) as t(uid)
  )
  select
    v.id,
    v.visited_at,
    v.title,
    v.summary,
    v.transcript,
    v.top_quote,
    v.tags,
    v.rating_label,
    v.return_intent,
    v.kind,
    pl.id,
    pl.name,
    pl.category,
    pl.neighborhood,
    pl.street_address,
    pl.latitude,
    pl.longitude,
    pr.id,
    pr.username::text,
    pr.display_name,
    pr.avatar_url,
    coalesce(
      (
        select jsonb_agg(
                 jsonb_build_object(
                   'id',           ph.id,
                   'storage_path', ph.storage_path,
                   'thumb_path',   ph.thumb_path,
                   'sort_order',   ph.sort_order
                 )
                 order by ph.sort_order
               )
        from public.visit_photos ph
        where ph.visit_id = v.id
      ),
      '[]'::jsonb
    ),
    -- "how many friends have been to that place". Distinct people, not visits:
    -- one friend who goes weekly is one friend.
    (
      select count(distinct v2.user_id)::int
      from public.visits v2
      where v2.place_id   = v.place_id
        and v2.kind       = 'visited'
        and v2.deleted_at is null
        and v2.user_id in (select uid from circle)
    )
  from public.visits v
  join public.places   pl on pl.id = v.place_id
  join public.profiles pr on pr.id = v.user_id
  where v.deleted_at is null
    and v.kind = 'visited'
    and v.user_id in (select uid from circle)
    and (
      p_cursor_visited_at is null
      or p_cursor_id is null
      or (v.visited_at, v.id) < (p_cursor_visited_at, p_cursor_id)
    )
  order by v.visited_at desc, v.id desc
  limit greatest(1, least(coalesce(p_limit, 20), 50));
$$;

comment on function public.friend_feed(timestamptz, uuid, int) is
  'Chronological friend activity, keyset-paginated on (visited_at, id). No ranking.';

-- Query: the feed's index range scan — friend ids, live visited rows, ordered by
-- the exact cursor tuple. `visits_user_live_visited_at_idx` stops at visited_at,
-- so ties fall back to a sort; including id makes the whole ORDER BY indexed.
create index if not exists visits_feed_cursor_idx
  on public.visits (user_id, visited_at desc, id desc)
  where deleted_at is null;


-- ----------------------------------------------------------------------------
-- Index gap found while writing the aggregates
-- ----------------------------------------------------------------------------
-- 0500_social.sql indexed `recommendations` for the inbox —
-- (recipient_id, status, created_at desc) — which was the only query anyone had
-- in mind at the time.
--
-- Both `wishlist_entries` and `place_social` ask a different question: "who
-- recommended THIS PLACE to me". That is (recipient_id, place_id), which the
-- inbox index cannot serve — `status` sits between the two columns it needs. It
-- runs as a filter on the recipient's whole recommendation history, per wishlist
-- row, which is fine at ten items and not at three hundred.
create index if not exists recommendations_recipient_place_idx
  on public.recommendations (recipient_id, place_id);


-- ----------------------------------------------------------------------------
-- 6. Social stats
-- ----------------------------------------------------------------------------
-- All three are cheap aggregates the local mirror cannot answer, because it only
-- holds the signed-in user's own rows. They are read behind a short client-side
-- TTL — a friend count that is thirty seconds stale is not a defect.

-- Place detail: who among my friends has been here, and where do I stand.
create or replace function public.place_social(p_place uuid)
returns table (
  place_id           uuid,
  friend_visit_count int,
  friend_place_count int,
  friends            jsonb,
  i_have_visited     boolean,
  on_my_wishlist     boolean,
  wishlist_item_id   uuid,
  recommenders       jsonb
)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  with circle as (
    select t.uid from public.friend_ids(auth.uid()) as t(uid)
  ),
  friend_visits as (
    select v.user_id, count(*)::int as visits
    from public.visits v
    where v.place_id   = p_place
      and v.kind       = 'visited'
      and v.deleted_at is null
      and v.user_id in (select uid from circle)
    group by v.user_id
  )
  select
    p_place,
    coalesce((select sum(fv.visits)::int from friend_visits fv), 0),
    (select count(*)::int from friend_visits),
    coalesce(
      (
        select jsonb_agg(
                 jsonb_build_object(
                   'id',           pr.id,
                   'username',     pr.username::text,
                   'display_name', pr.display_name,
                   'avatar_url',   pr.avatar_url,
                   'visit_count',  fv.visits
                 )
                 order by fv.visits desc, pr.display_name
               )
        from friend_visits fv
        join public.profiles pr on pr.id = fv.user_id
      ),
      '[]'::jsonb
    ),
    exists (
      select 1 from public.visits v
      where v.user_id    = auth.uid()
        and v.place_id   = p_place
        and v.kind       = 'visited'
        and v.deleted_at is null
    ),
    exists (
      select 1 from public.wishlist_items w
      where w.user_id = auth.uid() and w.place_id = p_place
    ),
    (
      select w.id from public.wishlist_items w
      where w.user_id = auth.uid() and w.place_id = p_place
    ),
    coalesce(
      (
        select jsonb_agg(
                 jsonb_build_object(
                   'id',           sp.id,
                   'username',     sp.username::text,
                   'display_name', sp.display_name,
                   'avatar_url',   sp.avatar_url,
                   'message',      r.message,
                   'created_at',   r.created_at
                 )
                 order by r.created_at
               )
        from public.recommendations r
        join public.profiles sp on sp.id = r.sender_id
        where r.recipient_id = auth.uid()
          and r.place_id     = p_place
      ),
      '[]'::jsonb
    );
$$;

-- Friend profile: what we have in common. `friend_profile()` from 0200 already
-- returns their counts and first-visit date; this is additive rather than a
-- change to that function's return type, which would require dropping it.
create or replace function public.friend_overlap(p_user uuid)
returns table (
  user_id          uuid,
  places_in_common int,
  common_places    jsonb
)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  with mine as (
    select distinct v.place_id
    from public.visits v
    where v.user_id = auth.uid() and v.kind = 'visited' and v.deleted_at is null
  ),
  theirs as (
    select distinct v.place_id
    from public.visits v
    where v.user_id = p_user and v.kind = 'visited' and v.deleted_at is null
  ),
  shared as (
    select m.place_id from mine m join theirs t on t.place_id = m.place_id
  )
  select
    p_user,
    (select count(*)::int from shared),
    coalesce(
      (
        select jsonb_agg(
                 jsonb_build_object(
                   'id',       pl.id,
                   'name',     pl.name,
                   'category', pl.category
                 )
                 order by pl.name
               )
        from shared s
        join public.places pl on pl.id = s.place_id
      ),
      '[]'::jsonb
    );
$$;

-- Own profile: friend count, and the gap — places friends rate that you haven't
-- been to. Ordered by how many friends have been, which is the closest thing to
-- a signal available without inventing a ranking.
create or replace function public.own_social_stats(p_gap_limit int default 10)
returns table (
  friend_count int,
  gap_count    int,
  gap_places   jsonb
)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  with circle as (
    select t.uid from public.friend_ids(auth.uid()) as t(uid)
  ),
  mine as (
    select distinct v.place_id
    from public.visits v
    where v.user_id = auth.uid() and v.kind = 'visited' and v.deleted_at is null
  ),
  gap as (
    select
      v.place_id,
      count(distinct v.user_id)::int as friends_here
    from public.visits v
    where v.kind       = 'visited'
      and v.deleted_at is null
      and v.user_id in (select uid from circle)
      and v.place_id not in (select place_id from mine)
    group by v.place_id
  )
  select
    (select count(*)::int from circle),
    (select count(*)::int from gap),
    coalesce(
      (
        select jsonb_agg(
                 jsonb_build_object(
                   'id',           pl.id,
                   'name',         pl.name,
                   'category',     pl.category,
                   'neighborhood', pl.neighborhood,
                   'latitude',     pl.latitude,
                   'longitude',    pl.longitude,
                   'friend_count', g.friends_here
                 )
                 order by g.friends_here desc, pl.name
               )
        from (
          select * from gap
          order by friends_here desc
          limit greatest(1, least(coalesce(p_gap_limit, 10), 50))
        ) g
        join public.places pl on pl.id = g.place_id
      ),
      '[]'::jsonb
    );
$$;


-- ----------------------------------------------------------------------------
-- Grants
-- ----------------------------------------------------------------------------
-- `wishlist_insert_for_recipient` is deliberately absent. It is SECURITY DEFINER
-- and writes a row owned by someone else; the only legitimate caller is
-- `recommend_place`, which reaches it with definer rights regardless. Granting
-- it to `authenticated` would hand every client the ability to put arbitrary
-- places on arbitrary users' wishlists.
revoke all on function public.wishlist_insert_for_recipient(uuid, uuid, uuid, uuid) from public;
revoke all on function public.wishlist_insert_for_recipient(uuid, uuid, uuid, uuid) from authenticated;
revoke all on function public.wishlist_insert_for_recipient(uuid, uuid, uuid, uuid) from anon;

revoke all on function public.recommend_place(uuid, uuid[], text)      from public;
revoke all on function public.inbox_recommendations()                  from public;
revoke all on function public.mark_recommendations_read(uuid[])        from public;
revoke all on function public.wishlist_entries(boolean)                from public;
revoke all on function public.wishlist_add(uuid)                       from public;
revoke all on function public.friend_feed(timestamptz, uuid, int)      from public;
revoke all on function public.place_social(uuid)                       from public;
revoke all on function public.friend_overlap(uuid)                     from public;
revoke all on function public.own_social_stats(int)                    from public;

grant execute on function public.recommend_place(uuid, uuid[], text)   to authenticated;
grant execute on function public.inbox_recommendations()               to authenticated;
grant execute on function public.mark_recommendations_read(uuid[])     to authenticated;
grant execute on function public.wishlist_entries(boolean)             to authenticated;
grant execute on function public.wishlist_add(uuid)                    to authenticated;
grant execute on function public.friend_feed(timestamptz, uuid, int)   to authenticated;
grant execute on function public.place_social(uuid)                    to authenticated;
grant execute on function public.friend_overlap(uuid)                  to authenticated;
grant execute on function public.own_social_stats(int)                 to authenticated;


-- ----------------------------------------------------------------------------
-- A note on `recommendations` privacy, since this is the one private table
-- ----------------------------------------------------------------------------
-- `recommendations_select_parties` restricts SELECT to sender and recipient, and
-- every read path above respects it without being asked to:
--
--   * `inbox_recommendations` filters `recipient_id = auth.uid()` explicitly, so
--     it is correct even if the policy were removed.
--   * `wishlist_entries` and `place_social` aggregate recommendations WITHOUT an
--     explicit recipient filter in the subquery — they rely on RLS. That is
--     intentional and is the thing worth testing: query `recommendations`
--     directly as an unrelated third user and you should get zero rows, and
--     these aggregates should return `[]` rather than someone else's senders.
--
-- Every function in this file is SECURITY INVOKER except
-- `wishlist_insert_for_recipient` and the resolution trigger, neither of which
-- reads `recommendations`. Nothing here can leak a recommendation.
