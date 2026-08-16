-- ============================================================================
-- 0816.0200 — The friend graph, exercised for the first time
-- ============================================================================
-- 0500_social.sql created `friendships`, `are_friends()` and `friend_ids()`
-- speculatively — nothing read them. This migration is written while actually
-- wiring the app to them, so it is both the first real use and the first real
-- audit. Findings, in order of how much they matter:
--
--   1. RLS HELD, with one integrity hole. The UPDATE policies correctly stop the
--      requester from accepting their own request (see the note on
--      `friendships_parties_immutable` below for the full case analysis) — but
--      nothing pinned `requester_id` / `addressee_id` across an UPDATE, so a
--      party could rewrite a row onto a third person. Fixed here with a trigger,
--      because RLS is row-scoped and cannot express "this column may not change".
--
--   2. `friend_ids()` was awkward to call and is now used where it belongs:
--      inside `visits_in_bounds` as the default audience, so the client never has
--      to send a friend list it just fetched.
--
--   3. `are_friends()` was fine as-is. `friend_profile()` uses it to answer "is
--      this still a friend?" on a profile the viewer may have been looking at
--      when the friendship ended.
--
-- Everything here is idempotent.
-- ============================================================================

set search_path = public, extensions;


-- ----------------------------------------------------------------------------
-- 1. Integrity fix: the two parties to a friendship are immutable
-- ----------------------------------------------------------------------------
-- Postgres ORs permissive policies of the same command, so the two UPDATE
-- policies on `friendships` combine to:
--
--   USING       (addressee and pending)  OR (party)
--   WITH CHECK  (addressee and accepted) OR (party and blocked)
--
-- Walking the cases that matter:
--   * requester tries to accept  -> USING passes via the block policy, but
--     WITH CHECK fails both branches (not the addressee; status isn't 'blocked').
--     Correctly denied. The client sees PostgREST's "0 rows" error rather than a
--     permission error, which is confusing but not wrong.
--   * anyone tries to un-accept  -> WITH CHECK allows only 'accepted' or
--     'blocked'. Correctly denied.
--   * a party rewrites the OTHER party while setting status = 'blocked' ->
--     both halves pass, because WITH CHECK only requires that the caller is
--     still one of the two parties on the NEW row.
--
-- That last one is the hole. A could take an accepted (A,B) row and rewrite it
-- to (A,C,'blocked'): it destroys A<->B (which A was entitled to do by DELETE
-- anyway) but also fabricates a blocked row against C, who never interacted with
-- A — and because of the unique pair index, that row then squats the {A,C} slot
-- and stops C from ever sending A a request.
--
-- A column-level GRANT can't fix this: the caller legitimately needs UPDATE on
-- `status`, and revoking UPDATE on the id columns would not stop a policy-passing
-- write of them via the same statement. A BEFORE UPDATE trigger is the right
-- tool — it sees old and new and is not bypassable from the client.
create or replace function public.friendships_parties_immutable()
returns trigger
language plpgsql
as $$
begin
  if new.requester_id is distinct from old.requester_id
     or new.addressee_id is distinct from old.addressee_id then
    raise exception
      'friendships: requester_id and addressee_id cannot be changed; delete the row instead'
      using errcode = '42501';
  end if;
  return new;
end;
$$;

drop trigger if exists friendships_parties_immutable_trg on public.friendships;
create trigger friendships_parties_immutable_trg
  before update on public.friendships
  for each row execute function public.friendships_parties_immutable();


-- ----------------------------------------------------------------------------
-- 2. search_profiles — user search with relationship state, in one query
-- ----------------------------------------------------------------------------
-- The relationship state per row is the whole reason this is a function. Doing
-- it client-side means a second query per result to ask "are we friends, did I
-- request them, did they request me" — 25 results, 26 requests. The LEFT JOIN
-- below answers it for the whole page at once, on the same index the unique
-- constraint already maintains.
--
-- Ranking: prefix matches ahead of substring matches. Both go through the
-- trigram GIN indexes from 0200_profiles.sql, which is why `username` is
-- compared as `::text` — the index is built on that projection, and citext's
-- own case-insensitive operators would not use it.
--
-- SECURITY INVOKER on purpose. `profiles` is world-readable to authenticated
-- users and the friendships SELECT policy already exposes exactly the rows the
-- caller is a party to, so running as the caller yields the correct answer with
-- no privilege escalation to reason about.
create or replace function public.search_profiles(
  p_query text,
  p_limit int default 25
)
returns table (
  id            uuid,
  username      text,
  display_name  text,
  avatar_url    text,
  bio           text,
  relationship  text,
  friendship_id uuid
)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select
    p.id,
    p.username::text,
    p.display_name,
    p.avatar_url,
    p.bio,
    case
      when p.id = auth.uid()        then 'self'
      when f.id is null             then 'none'
      when f.status = 'accepted'    then 'friends'
      when f.status = 'blocked'     then 'blocked'
      when f.requester_id = auth.uid() then 'outgoing'
      else                               'incoming'
    end,
    f.id
  from public.profiles p
  left join public.friendships f
    on least(f.requester_id, f.addressee_id)    = least(p.id, auth.uid())
   and greatest(f.requester_id, f.addressee_id) = greatest(p.id, auth.uid())
  where btrim(coalesce(p_query, '')) <> ''
    -- No username means onboarding never finished. Such a row has no handle to
    -- match and no identity to show, so it is not a findable person.
    and p.username is not null
    and (
         p.username::text ilike btrim(p_query) || '%'
      or p.display_name   ilike btrim(p_query) || '%'
      or p.username::text ilike '%' || btrim(p_query) || '%'
      or p.display_name   ilike '%' || btrim(p_query) || '%'
    )
  order by
    case
      when p.username::text ilike btrim(p_query) || '%'
        or p.display_name   ilike btrim(p_query) || '%' then 0
      else 1
    end,
    coalesce(p.display_name, p.username::text)
  limit greatest(1, least(coalesce(p_limit, 25), 50));
$$;

comment on function public.search_profiles(text, int) is
  'User search by handle or display name, with the caller''s relationship to each result.';


-- ----------------------------------------------------------------------------
-- 3. send_friend_request — including the simultaneous-request collision
-- ----------------------------------------------------------------------------
-- The unique index on (least(pair), greatest(pair)) means that when A requests B
-- at the same moment B requests A, the second INSERT raises 23505. That is not
-- an error condition: both people have now said yes, which is the definition of
-- a friendship. This promotes the existing row to 'accepted' instead.
--
-- Why a function and not read-then-write in Swift: between "select existing" and
-- "update it" the other device can accept, decline, or delete. Here the whole
-- thing is one statement from the caller's perspective, and the SELECT takes a
-- row lock (FOR UPDATE) that the racing session must wait behind.
--
-- Why SECURITY INVOKER and not DEFINER: every step is something the client is
-- already permitted to do — INSERT as requester with status 'pending', and
-- UPDATE pending -> accepted as the addressee. Running as the caller means the
-- policies from 0600_rls.sql are the enforcement, not a second copy of them
-- written inside this function that can drift. If the collision branch ever
-- stops working, that is RLS telling us something true.
--
-- Idempotent in every non-collision case: asking twice, or asking someone who is
-- already a friend, returns the existing row rather than raising.
create or replace function public.send_friend_request(p_addressee uuid)
returns public.friendships
language plpgsql
security invoker
set search_path = public, extensions
as $$
declare
  v_me       uuid := auth.uid();
  v_existing public.friendships;
  v_result   public.friendships;
begin
  if v_me is null then
    raise exception 'send_friend_request: authentication required'
      using errcode = '28000';
  end if;

  if p_addressee is null then
    raise exception 'send_friend_request: addressee is required'
      using errcode = '22023';
  end if;

  if p_addressee = v_me then
    raise exception 'send_friend_request: cannot send a friend request to yourself'
      using errcode = '22023';
  end if;

  -- Happy path. The sub-block is a subtransaction: if the insert violates the
  -- pair index it rolls back to here and execution continues below, rather than
  -- aborting the whole call.
  begin
    insert into public.friendships (requester_id, addressee_id, status)
    values (v_me, p_addressee, 'pending')
    returning * into v_result;

    return v_result;
  exception
    when unique_violation then
      null;  -- a row for this pair already exists; fall through and inspect it
  end;

  -- READ COMMITTED gives this statement a fresh snapshot, so the row that beat
  -- us to the index is visible here even though it was invisible to the
  -- transaction when the INSERT began.
  --
  -- FOR UPDATE locks the row so the racing session has to queue behind us
  -- instead of both of us deciding what to do with it. One subtlety worth
  -- recording: under RLS, SELECT ... FOR UPDATE applies the UPDATE policies'
  -- USING clauses on top of the SELECT policy. That is satisfied here only
  -- because `friendships_block_by_party` has a USING clause of "am I a party to
  -- this row", which is always true for us — the pair index can only conflict on
  -- a pair we are half of. If that policy is ever narrowed or dropped, this lock
  -- starts failing for the already-accepted and already-requested branches, and
  -- the symptom will look like a permissions bug in send_friend_request rather
  -- than a change over there.
  select * into v_existing
  from public.friendships f
  where least(f.requester_id, f.addressee_id)    = least(v_me, p_addressee)
    and greatest(f.requester_id, f.addressee_id) = greatest(v_me, p_addressee)
  for update;

  if v_existing.id is null then
    -- Unreachable in practice: the pair index only covers this pair, and the
    -- SELECT policy shows every row the caller is a party to. If it ever fires,
    -- the policy changed underneath us and a clear error beats a silent null.
    raise exception 'send_friend_request: a conflicting friendship exists but is not visible'
      using errcode = 'P0002';
  end if;

  if v_existing.status = 'blocked' then
    raise exception 'send_friend_request: this friendship is blocked'
      using errcode = '42501';
  end if;

  -- Already friends. Returning the row rather than raising keeps the client
  -- simple: a stale "Add friend" button just re-derives the true state.
  if v_existing.status = 'accepted' then
    return v_existing;
  end if;

  -- Pending, and we are the one who asked. Tapping twice is not an error.
  if v_existing.requester_id = v_me then
    return v_existing;
  end if;

  -- THE COLLISION. They asked us, we asked them, neither knew. Both parties
  -- expressed intent, so this is an acceptance.
  --
  -- Note that we are the ADDRESSEE of v_existing, which is exactly what
  -- `friendships_accept_by_addressee` requires — this UPDATE is checked by the
  -- same policy that a normal Accept tap goes through.
  update public.friendships
     set status = 'accepted'
   where id = v_existing.id
  returning * into v_result;

  return v_result;
end;
$$;

comment on function public.send_friend_request(uuid) is
  'Sends a friend request. If the addressee already requested the caller, promotes that row to accepted instead of failing on the pair index.';


-- ----------------------------------------------------------------------------
-- 4. friendship_edges — friends list, both request queues, and the badge
-- ----------------------------------------------------------------------------
-- One call backs four surfaces. Splitting it into "my friends" / "incoming" /
-- "outgoing" would be three requests over the same index for data that is always
-- displayed together, and the badge count would be a fourth.
--
-- Each row is the OTHER party plus the caller's direction, so no client-side
-- "which column am I in" branching survives past this boundary.
create or replace function public.friendship_edges()
returns table (
  friendship_id uuid,
  status        text,
  direction     text,
  created_at    timestamptz,
  responded_at  timestamptz,
  user_id       uuid,
  username      text,
  display_name  text,
  avatar_url    text,
  bio           text
)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select
    f.id,
    f.status,
    case when f.requester_id = auth.uid() then 'outgoing' else 'incoming' end,
    f.created_at,
    f.responded_at,
    p.id,
    p.username::text,
    p.display_name,
    p.avatar_url,
    p.bio
  from public.friendships f
  join public.profiles p
    on p.id = case
                when f.requester_id = auth.uid() then f.addressee_id
                else f.requester_id
              end
  where auth.uid() in (f.requester_id, f.addressee_id)
    -- 'blocked' is deliberately excluded: it belongs to neither the friends list
    -- nor either request queue, and there is no block-management UI yet.
    and f.status in ('pending', 'accepted')
  order by coalesce(p.display_name, p.username::text);
$$;

comment on function public.friendship_edges() is
  'Every pending or accepted friendship the caller is party to, flattened to the other party plus a direction.';


-- ----------------------------------------------------------------------------
-- 5. visits_in_bounds — the map query
-- ----------------------------------------------------------------------------
-- Server-side because a bounding box belongs next to the data: filtering, then
-- ordering by recency, then capping happens before anything crosses the network.
-- The PostgREST equivalent would be four range filters plus an `in` list, and it
-- could not cap "the 200 most recent" without pulling the whole set first.
--
-- Deviation from the brief's signature: the cap parameter is `result_limit`, not
-- `limit`. `limit` is a reserved word and would have to be double-quoted at
-- every call site including the PostgREST JSON body.
--
-- ANTIMERIDIAN: handled. A box that wraps 180° arrives with min_lng > max_lng
-- (e.g. 179 -> -179), where `between` matches nothing. The CASE detects the wrap
-- and switches to a disjunction. NYC will never hit this; a user panning the
-- Pacific will, and an empty map there reads as a bug.
--
-- NULL / empty `user_ids` means "me and my friends" and is resolved with
-- `friend_ids()`, so the common case costs the client nothing to express.
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
  photos         jsonb
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
    -- Photos inlined rather than left to a second round trip. A place sheet
    -- opens on tap and needs them immediately; fetching per visit would be one
    -- request per pin the user touches.
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
    )
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
  'Live visits inside a lat/lng box for a set of users (default: caller + friends), newest first, capped. Handles antimeridian wrap.';


-- ----------------------------------------------------------------------------
-- 5b. user_visits — the same rows, without a box
-- ----------------------------------------------------------------------------
-- A friend's profile shows their visits as a list, which is `visits_in_bounds`
-- minus the bounds. Rather than write the join, the photo aggregation and the
-- soft-delete filter a second time, this delegates with world bounds.
--
-- Sharing the return shape is the point: the profile list, the map, and the
-- place detail sheet all decode into one type on the client, so a column added
-- to one surface appears on all three instead of drifting.
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
  photos         jsonb
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
-- 6. friend_profile — header, stats, and "are we still friends"
-- ----------------------------------------------------------------------------
-- Everything here is world-readable, so there is no permission branching — the
-- `is_friend` flag is for the UI's action button, not for redaction.
--
-- Returning ZERO ROWS is a meaningful answer: it means the profile is gone,
-- which is what the client sees when someone deletes their account while being
-- viewed. That is cleaner than a row full of nulls.
create or replace function public.friend_profile(p_user uuid)
returns table (
  id                uuid,
  username          text,
  display_name      text,
  avatar_url        text,
  bio               text,
  is_friend         boolean,
  is_self           boolean,
  visit_count       bigint,
  want_to_try_count bigint,
  place_count       bigint,
  first_visit_at    timestamptz,
  last_visit_at     timestamptz
)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select
    p.id,
    p.username::text,
    p.display_name,
    p.avatar_url,
    p.bio,
    public.are_friends(auth.uid(), p.id),
    p.id = auth.uid(),
    count(v.id) filter (where v.kind = 'visited'),
    count(v.id) filter (where v.kind = 'wantToTry'),
    count(distinct v.place_id) filter (where v.kind = 'visited'),
    min(v.visited_at) filter (where v.kind = 'visited'),
    max(v.visited_at) filter (where v.kind = 'visited')
  from public.profiles p
  left join public.visits v
    on v.user_id = p.id
   and v.deleted_at is null
  where p.id = p_user
  group by p.id;
$$;

comment on function public.friend_profile(uuid) is
  'Public profile header plus visit stats. Zero rows means the account no longer exists.';


-- ----------------------------------------------------------------------------
-- Grants
-- ----------------------------------------------------------------------------
-- Same pattern as everywhere else: nothing for `public` or `anon`, execute for
-- `authenticated`. These functions are SECURITY INVOKER, so a grant is only
-- permission to call them — RLS still decides what comes back.
revoke all on function public.search_profiles(text, int) from public;
revoke all on function public.send_friend_request(uuid) from public;
revoke all on function public.friendship_edges() from public;
revoke all on function public.visits_in_bounds(double precision, double precision, double precision, double precision, uuid[], int) from public;
revoke all on function public.user_visits(uuid, int) from public;
revoke all on function public.friend_profile(uuid) from public;

grant execute on function public.search_profiles(text, int) to authenticated;
grant execute on function public.send_friend_request(uuid) to authenticated;
grant execute on function public.friendship_edges() to authenticated;
grant execute on function public.visits_in_bounds(double precision, double precision, double precision, double precision, uuid[], int) to authenticated;
grant execute on function public.user_visits(uuid, int) to authenticated;
grant execute on function public.friend_profile(uuid) to authenticated;


-- ----------------------------------------------------------------------------
-- A note on declining, since it is a schema decision and not a UI one
-- ----------------------------------------------------------------------------
-- Declining DELETES the row. It does not set a 'declined' status.
--
-- Why: the pair index allows exactly one row per unordered pair, so a retained
-- 'declined' row permanently occupies that slot. The person who declined can
-- never be re-added later without an explicit un-decline path, and — worse — the
-- decline is legible to the other party, because their outgoing request would
-- have to either vanish (indistinguishable from a delete) or show as rejected.
-- Silence is the kinder and more common product answer, and deleting makes
-- "they never responded" and "they declined" look identical from the outside.
--
-- The cost is real: nothing stops an immediate re-request, so a determined
-- person can re-send in a loop. That is the harassment case, and the fix is NOT
-- to switch to a tombstone — it is `status = 'blocked'`, which already exists in
-- the CHECK constraint and already has an UPDATE policy. If it becomes a
-- problem, the changes are: surface Block in the decline dialog, and add a
-- `declined_at` column that `send_friend_request` consults to rate-limit
-- re-requests (e.g. one per pair per 30 days) without ever revealing the decline
-- to the requester. Both are additive to what is here.
