-- ============================================================================
-- 0500 — friendships, recommendations, wishlist_items
-- ============================================================================
-- Nothing in the app reads these tables yet. They exist now because writing the
-- migration alongside the rest is nearly free, and retrofitting a friend graph
-- onto a populated database is not.
--
-- Note on the friend graph: it is a FILTERING mechanism, not a permission
-- mechanism. Every visit, photo, transcript and summary is readable by any
-- authenticated user (see 0600_rls.sql). Being friends decides what shows up on
-- your map, never what you are allowed to see.
-- ============================================================================

set search_path = public, extensions;

-- ----------------------------------------------------------------------------
-- friendships — mutual, one row per relationship
-- ----------------------------------------------------------------------------
create table if not exists public.friendships (
  id            uuid primary key default gen_random_uuid(),
  requester_id  uuid not null references public.profiles(id) on delete cascade,
  addressee_id  uuid not null references public.profiles(id) on delete cascade,

  status        text not null default 'pending'
                check (status in ('pending', 'accepted', 'blocked')),

  created_at    timestamptz not null default now(),
  responded_at  timestamptz,

  constraint friendships_no_self check (requester_id <> addressee_id)
);

-- THE constraint that makes this graph mutual rather than two directed edges.
-- Without it, A->B pending and B->A pending can both exist, and every read has
-- to defensively de-duplicate. Ordering the pair with least/greatest makes the
-- unordered pair {A,B} a single indexable value.
create unique index if not exists friendships_unique_pair_idx
  on public.friendships (least(requester_id, addressee_id), greatest(requester_id, addressee_id));

comment on table public.friendships is
  'Mutual friendship. Exactly one row per unordered pair, in either direction.';

-- Stamp responded_at whenever status leaves 'pending', so the client cannot lie
-- about when a request was accepted.
create or replace function public.friendships_stamp_response()
returns trigger
language plpgsql
as $$
begin
  if new.status is distinct from old.status and new.status <> 'pending' then
    new.responded_at = now();
  end if;
  return new;
end;
$$;

drop trigger if exists friendships_stamp_response_trg on public.friendships;
create trigger friendships_stamp_response_trg
  before update on public.friendships
  for each row execute function public.friendships_stamp_response();


-- ----------------------------------------------------------------------------
-- Friend-graph helpers (used by later tasks: map layers, feed, "3 friends here")
-- ----------------------------------------------------------------------------

-- True only when an ACCEPTED row exists, in either direction. 'pending' and
-- 'blocked' are both false.
create or replace function public.are_friends(user_a uuid, user_b uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.friendships f
    where f.status = 'accepted'
      and (
        (f.requester_id = user_a and f.addressee_id = user_b) or
        (f.requester_id = user_b and f.addressee_id = user_a)
      )
  );
$$;

-- Every accepted friend of `for_user`, direction-agnostic. Returns the OTHER
-- party's id, never `for_user` itself.
create or replace function public.friend_ids(for_user uuid)
returns setof uuid
language sql
stable
security definer
set search_path = public
as $$
  select case
           when f.requester_id = for_user then f.addressee_id
           else f.requester_id
         end
  from public.friendships f
  where f.status = 'accepted'
    and for_user in (f.requester_id, f.addressee_id);
$$;

revoke all on function public.are_friends(uuid, uuid) from public;
revoke all on function public.friend_ids(uuid) from public;
grant execute on function public.are_friends(uuid, uuid) to authenticated;
grant execute on function public.friend_ids(uuid) to authenticated;


-- ----------------------------------------------------------------------------
-- recommendations — "you should go here"
-- ----------------------------------------------------------------------------
create table if not exists public.recommendations (
  id           uuid primary key default gen_random_uuid(),
  sender_id    uuid not null references public.profiles(id) on delete cascade,
  recipient_id uuid not null references public.profiles(id) on delete cascade,
  place_id     uuid not null references public.places(id)   on delete cascade,

  message      text,
  status       text not null default 'unread'
               check (status in ('unread', 'read', 'dismissed')),

  created_at   timestamptz not null default now(),
  read_at      timestamptz,

  constraint recommendations_no_self check (sender_id <> recipient_id),
  constraint recommendations_message_length
    check (message is null or char_length(message) <= 500),

  -- Anti-spam: one person can recommend a given place to a given person exactly
  -- once. Re-sending is a no-op rather than a second inbox row.
  constraint recommendations_unique_per_place unique (sender_id, recipient_id, place_id)
);

comment on table public.recommendations is
  'Place sent from one user to another. The only table in the schema that is not world-readable.';


-- ----------------------------------------------------------------------------
-- wishlist_items — places you want to go
-- ----------------------------------------------------------------------------
create table if not exists public.wishlist_items (
  id                       uuid primary key default gen_random_uuid(),
  user_id                  uuid not null references public.profiles(id) on delete cascade,
  place_id                 uuid not null references public.places(id)   on delete cascade,

  source                   text not null default 'manual'
                           check (source in ('manual', 'recommendation')),

  -- Provenance when source = 'recommendation'. ON DELETE SET NULL: if the
  -- recommendation is later deleted, the wishlist item survives — the user still
  -- wants to go, they just lose the "from Sam" attribution.
  source_recommendation_id uuid references public.recommendations(id) on delete set null,

  -- How a wishlist item clears itself: when the user actually logs a visit here,
  -- point this at that visit instead of deleting the row, so the wishlist keeps a
  -- record of "wanted to go -> went".
  resolved_visit_id        uuid references public.visits(id) on delete set null,

  created_at               timestamptz not null default now(),
  resolved_at              timestamptz,

  constraint wishlist_items_unique_place unique (user_id, place_id)
);

-- Keep resolved_at and resolved_visit_id honest with respect to each other.
create or replace function public.wishlist_stamp_resolved()
returns trigger
language plpgsql
as $$
begin
  if new.resolved_visit_id is not null and new.resolved_at is null then
    new.resolved_at = now();
  elsif new.resolved_visit_id is null then
    new.resolved_at = null;
  end if;
  return new;
end;
$$;

drop trigger if exists wishlist_stamp_resolved_trg on public.wishlist_items;
create trigger wishlist_stamp_resolved_trg
  before insert or update on public.wishlist_items
  for each row execute function public.wishlist_stamp_resolved();


-- ----------------------------------------------------------------------------
-- Indexes
-- ----------------------------------------------------------------------------

-- Query: incoming requests badge / list —
--   `where addressee_id = $1 and status = 'pending'`
create index if not exists friendships_addressee_status_idx
  on public.friendships (addressee_id, status);

-- Query: outgoing requests + "my friends" list —
--   `where requester_id = $1 and status = 'accepted'`
create index if not exists friendships_requester_status_idx
  on public.friendships (requester_id, status);

-- Query: recommendations inbox —
--   `where recipient_id = $1 and status = 'unread' order by created_at desc`
create index if not exists recommendations_inbox_idx
  on public.recommendations (recipient_id, status, created_at desc);

-- Query: active wishlist (things not yet visited) —
--   `where user_id = $1 and resolved_visit_id is null`
-- Partial so the index only carries live rows; resolved items grow without bound
-- and are never in this query's result.
create index if not exists wishlist_items_active_idx
  on public.wishlist_items (user_id)
  where resolved_visit_id is null;

-- Query: "who else wants to go here" on a place sheet — `where place_id = $1`
create index if not exists wishlist_items_place_idx
  on public.wishlist_items (place_id);
