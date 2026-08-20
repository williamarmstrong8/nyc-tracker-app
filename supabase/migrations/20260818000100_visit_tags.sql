-- ============================================================================
-- 0818.0100 — Tagging people in a visit
-- ============================================================================
-- "I was here with Sam and Alex." One row per (visit, person). No note, no
-- ordering column, no approval state — a tag is a fact about who was there, and
-- everything else is a product feature that can be added on top of this without
-- reshaping it.
--
-- Two decisions worth recording, because both are enforced here rather than in
-- the client:
--
--   1. YOU CAN ONLY TAG AN ACCEPTED FRIEND. The insert policy checks
--      `are_friends()`. Without it, tagging is an unsolicited write onto a
--      stranger's "Tagged" tab from anyone who knows their user id — the same
--      shape as the mention-spam problem every social app eventually has to
--      retrofit a fix for. The friend graph already exists, so the fix is free
--      now and expensive later.
--
--   2. THE TAGGED PERSON CAN REMOVE THEIR OWN TAG. The delete policy admits
--      both the visit's author and the tagged user. Being named in someone
--      else's post is the one thing here that shows up on your profile without
--      you writing it, so the exit has to belong to you and not to the author.
--
-- Everything is idempotent.
-- ============================================================================

set search_path = public, extensions;


-- ----------------------------------------------------------------------------
-- 1. The table
-- ----------------------------------------------------------------------------
-- The composite primary key is the dedupe: tagging the same person twice in one
-- visit is not a second fact, and an upsert on conflict is how the client
-- re-sends a tag set without diffing it first.
create table if not exists public.visit_tags (
  visit_id   uuid        not null references public.visits(id)   on delete cascade,
  user_id    uuid        not null references public.profiles(id) on delete cascade,
  -- The author's chosen order, so "with Sam and Alex" reads the same on every
  -- device. Not derived from `created_at`: the client replaces the whole set in
  -- one statement, which would give every row the same timestamp and leave the
  -- display order to whatever tiebreak the reader picked.
  sort_order int         not null default 0,
  created_at timestamptz not null default now(),

  primary key (visit_id, user_id)
);

comment on table public.visit_tags is
  'People tagged as present at a visit. One row per (visit, person); only accepted friends of the visit author may be tagged.';

-- Query: the "Tagged" tab — `where user_id = $1 order by created_at desc`.
-- The primary key already covers the (visit_id, ...) direction.
create index if not exists visit_tags_user_created_idx
  on public.visit_tags (user_id, created_at desc);


-- ----------------------------------------------------------------------------
-- 2. Author cannot tag themselves
-- ----------------------------------------------------------------------------
-- Not a CHECK constraint, because the answer lives in another table: the check
-- is `user_id <> visits.user_id`, and a CHECK cannot read a second row. A
-- trigger is the only place this can be true for every writer, including a
-- future admin path that bypasses RLS.
--
-- Why forbid it at all: the author is already on the visit — they wrote it. A
-- self-tag would make their own entry appear twice in their own Tagged tab, and
-- it makes "how many people were here" wrong by one everywhere it is counted.
create or replace function public.visit_tags_reject_self()
returns trigger
language plpgsql
set search_path = public, extensions
as $$
begin
  if exists (
    select 1 from public.visits v
    where v.id = new.visit_id
      and v.user_id = new.user_id
  ) then
    raise exception 'visit_tags: a visit''s author cannot be tagged in their own visit'
      using errcode = '22023';
  end if;
  return new;
end;
$$;

drop trigger if exists visit_tags_reject_self_trg on public.visit_tags;
create trigger visit_tags_reject_self_trg
  before insert or update on public.visit_tags
  for each row execute function public.visit_tags_reject_self();


-- ----------------------------------------------------------------------------
-- 3. RLS
-- ----------------------------------------------------------------------------
alter table public.visit_tags enable row level security;

revoke all on public.visit_tags from anon;
grant select, insert, update, delete on public.visit_tags to authenticated;

-- READ: any signed-in user, matching `visits` and `visit_photos`. A tag is not
-- more private than the visit it hangs off, and the visit is world-readable.
drop policy if exists visit_tags_select_authenticated on public.visit_tags;
create policy visit_tags_select_authenticated
  on public.visit_tags for select
  to authenticated
  using (true);

-- INSERT: only onto your own visit, and only naming an accepted friend.
--
-- `are_friends()` is SECURITY DEFINER (0500_social.sql), which matters: the
-- caller cannot read the friendships row for a pair they are not part of, so an
-- INVOKER check here would evaluate against an empty table and reject every
-- legitimate tag.
drop policy if exists visit_tags_insert_own_visit on public.visit_tags;
create policy visit_tags_insert_own_visit
  on public.visit_tags for insert
  to authenticated
  with check (
    exists (
      select 1 from public.visits v
      where v.id = visit_tags.visit_id
        and v.user_id = auth.uid()
    )
    and public.are_friends(auth.uid(), visit_tags.user_id)
  );

-- DELETE: the author untagging someone, or the tagged person untagging
-- themselves. See the note at the top of this file for why the second half is
-- not optional.
drop policy if exists visit_tags_delete_author_or_tagged on public.visit_tags;
create policy visit_tags_delete_author_or_tagged
  on public.visit_tags for delete
  to authenticated
  using (
    visit_tags.user_id = auth.uid()
    or exists (
      select 1 from public.visits v
      where v.id = visit_tags.visit_id
        and v.user_id = auth.uid()
    )
  );

-- UPDATE: the author, on their own visit, still naming a friend.
--
-- This exists for exactly one caller: the client replaces a tag set with an
-- upsert, and an upsert is `insert ... on conflict do update`. Re-tagging
-- someone who is already tagged (a retried sync, a reorder) takes the conflict
-- branch, and without a policy that branch is a 403 on an operation the user is
-- obviously allowed to perform.
--
-- The identity columns are not writable through it: the WITH CHECK re-tests
-- ownership and friendship against the NEW row, so a rewrite to a third party
-- fails the friendship test the same way a fresh insert would. In practice
-- `sort_order` is the only column that ever changes.
drop policy if exists visit_tags_update_own_visit on public.visit_tags;
create policy visit_tags_update_own_visit
  on public.visit_tags for update
  to authenticated
  using (
    exists (
      select 1 from public.visits v
      where v.id = visit_tags.visit_id
        and v.user_id = auth.uid()
    )
  )
  with check (
    exists (
      select 1 from public.visits v
      where v.id = visit_tags.visit_id
        and v.user_id = auth.uid()
    )
    and public.are_friends(auth.uid(), visit_tags.user_id)
  );


-- ----------------------------------------------------------------------------
-- 4. The shared `tagged` payload
-- ----------------------------------------------------------------------------
-- Every read surface (map, profile list, feed, tagged tab) inlines the same
-- jsonb array, for the same reason `photos` is inlined: a feed card renders the
-- avatars immediately, and a second round trip per visit would be one request
-- per row on screen.
--
-- Factored into a function so the four call sites cannot drift. STABLE and
-- INVOKER — it reads only world-readable tables.
create or replace function public.visit_tagged_json(p_visit uuid)
returns jsonb
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select coalesce(
    (
      select jsonb_agg(
               jsonb_build_object(
                 'user_id',      pr.id,
                 'username',     pr.username::text,
                 'display_name', pr.display_name,
                 'avatar_url',   pr.avatar_url
               )
               order by vt.sort_order, pr.id
             )
      from public.visit_tags vt
      join public.profiles pr on pr.id = vt.user_id
      where vt.visit_id = p_visit
    ),
    '[]'::jsonb
  );
$$;

comment on function public.visit_tagged_json(uuid) is
  'People tagged in a visit, as the jsonb array every visit-returning RPC inlines.';


-- ----------------------------------------------------------------------------
-- 5. Adding `tagged` to the visit-returning RPCs
-- ----------------------------------------------------------------------------
-- These are DROPped rather than CREATE OR REPLACEd: Postgres will not replace a
-- function whose RETURNS TABLE signature changed, and adding a column changes
-- it. `user_visits` delegates to `visits_in_bounds` through a quoted string
-- body, so there is no recorded dependency and no CASCADE is needed — but the
-- order still matters for anyone reading this top to bottom.
drop function if exists public.user_visits(uuid, int);
drop function if exists public.visits_in_bounds(
  double precision, double precision, double precision, double precision, uuid[], int
);
drop function if exists public.friend_feed(timestamptz, uuid, int);


create or replace function public.visits_in_bounds(
  min_lat      double precision,
  max_lat      double precision,
  min_lng      double precision,
  max_lng      double precision,
  user_ids     uuid[] default null,
  result_limit int default 200
)
returns table (
  visit_id       uuid,
  visited_at     timestamptz,
  title          text,
  summary        text,
  transcript     text,
  top_quote      text,
  tags           text[],
  rating_label   text,
  return_intent  text,
  kind           text,
  place_id       uuid,
  place_name     text,
  place_category text,
  neighborhood   text,
  street_address text,
  latitude       double precision,
  longitude      double precision,
  user_id        uuid,
  username       text,
  display_name   text,
  avatar_url     text,
  photos         jsonb,
  tagged         jsonb
)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  with targets as (
    select unnest(
      coalesce(
        nullif(user_ids, '{}'::uuid[]),
        array(select public.friend_ids(auth.uid())) || auth.uid()
      )
    ) as uid
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
    public.visit_tagged_json(v.id)
  from public.visits v
  join public.places   pl on pl.id = v.place_id
  join public.profiles pr on pr.id = v.user_id
  where v.deleted_at is null
    and v.user_id in (select uid from targets)
    and pl.latitude between min_lat and max_lat
    and case
          when min_lng <= max_lng then pl.longitude between min_lng and max_lng
          else pl.longitude >= min_lng or pl.longitude <= max_lng
        end
  order by v.visited_at desc
  limit greatest(1, least(coalesce(result_limit, 200), 500));
$$;

comment on function public.visits_in_bounds(double precision, double precision, double precision, double precision, uuid[], int) is
  'Live visits inside a lat/lng box for a set of users (default: caller + friends), newest first, capped. Handles antimeridian wrap. Includes tagged people.';


create or replace function public.user_visits(
  p_user  uuid,
  p_limit int default 100
)
returns table (
  visit_id       uuid,
  visited_at     timestamptz,
  title          text,
  summary        text,
  transcript     text,
  top_quote      text,
  tags           text[],
  rating_label   text,
  return_intent  text,
  kind           text,
  place_id       uuid,
  place_name     text,
  place_category text,
  neighborhood   text,
  street_address text,
  latitude       double precision,
  longitude      double precision,
  user_id        uuid,
  username       text,
  display_name   text,
  avatar_url     text,
  photos         jsonb,
  tagged         jsonb
)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select *
  from public.visits_in_bounds(
    -90, 90, -180, 180,
    array[p_user],
    coalesce(p_limit, 100)
  );
$$;

comment on function public.user_visits(uuid, int) is
  'One user''s live visits, newest first. Same row shape as visits_in_bounds.';


-- ----------------------------------------------------------------------------
-- 6. tagged_visits — the "Tagged" tab
-- ----------------------------------------------------------------------------
-- Visits somebody ELSE wrote in which `p_user` was tagged. Same row shape as
-- `visits_in_bounds`, so the profile page decodes both of its tabs into one
-- client type and the write-up sheet opens from either.
--
-- Not filtered to the caller's friends. Only an accepted friend of the author
-- can create a tag in the first place (see the insert policy), so the audience
-- question was already answered at write time; re-asking it at read time would
-- hide a person's own tags from them the moment a mutual friendship ended.
--
-- `wantToTry` rows are excluded: a bookmark is a plan, not an occasion, and
-- nobody was there to be tagged.
create or replace function public.tagged_visits(
  p_user  uuid,
  p_limit int default 100
)
returns table (
  visit_id       uuid,
  visited_at     timestamptz,
  title          text,
  summary        text,
  transcript     text,
  top_quote      text,
  tags           text[],
  rating_label   text,
  return_intent  text,
  kind           text,
  place_id       uuid,
  place_name     text,
  place_category text,
  neighborhood   text,
  street_address text,
  latitude       double precision,
  longitude      double precision,
  user_id        uuid,
  username       text,
  display_name   text,
  avatar_url     text,
  photos         jsonb,
  tagged         jsonb
)
language sql
stable
security invoker
set search_path = public, extensions
as $$
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
    public.visit_tagged_json(v.id)
  from public.visit_tags vt
  join public.visits   v  on v.id  = vt.visit_id
  join public.places   pl on pl.id = v.place_id
  join public.profiles pr on pr.id = v.user_id
  where vt.user_id = p_user
    and v.deleted_at is null
    and v.kind = 'visited'
  order by v.visited_at desc, v.id desc
  limit greatest(1, least(coalesce(p_limit, 100), 200));
$$;

comment on function public.tagged_visits(uuid, int) is
  'Visits in which a user was tagged by someone else, newest first. Same row shape as visits_in_bounds.';


-- ----------------------------------------------------------------------------
-- 7. friend_feed, with tagged people
-- ----------------------------------------------------------------------------
-- Unchanged except for the extra column. Reproduced in full because the body is
-- a string literal and there is no way to add one column to it in place.
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
  tagged              jsonb,
  friend_place_count  int
)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  with circle as (
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
    public.visit_tagged_json(v.id),
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
  'Friends'' visits, newest first, keyset-paginated. Includes tagged people and how many friends have been to the same place.';


-- ----------------------------------------------------------------------------
-- Grants
-- ----------------------------------------------------------------------------
-- The three recreated functions lost their grants when they were dropped.
revoke all on function public.visit_tagged_json(uuid) from public;
revoke all on function public.tagged_visits(uuid, int) from public;
revoke all on function public.user_visits(uuid, int) from public;
revoke all on function public.friend_feed(timestamptz, uuid, int) from public;
revoke all on function public.visits_in_bounds(
  double precision, double precision, double precision, double precision, uuid[], int
) from public;

grant execute on function public.visit_tagged_json(uuid)               to authenticated;
grant execute on function public.tagged_visits(uuid, int)              to authenticated;
grant execute on function public.user_visits(uuid, int)                to authenticated;
grant execute on function public.friend_feed(timestamptz, uuid, int)   to authenticated;
grant execute on function public.visits_in_bounds(
  double precision, double precision, double precision, double precision, uuid[], int
) to authenticated;
