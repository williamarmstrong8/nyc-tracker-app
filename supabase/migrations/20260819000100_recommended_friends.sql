-- ============================================================================
-- 0819.0100 — recommended_friends: people you may know
-- ============================================================================
-- The Add Friends screen's empty state used to just say "No requests". This
-- gives it something more useful to show instead: friends-of-friends the
-- caller isn't already connected to, ranked by how many friends they share.
--
-- `friend_ids()` (0500_social.sql) is SECURITY DEFINER, which is exactly what
-- makes the friends-of-friends expansion possible here — a caller has no RLS
-- visibility into a stranger's friendships, but this function already exists
-- and is trusted to answer "who is X friends with" for exactly this reason
-- (it backs `visits_in_bounds`'s default audience the same way).
--
-- Zero mutual friends means zero rows, not a low-quality suggestion: with no
-- shared connection there is nothing to recommend on, and the client's job is
-- to show nothing rather than pad the list with strangers.
set search_path = public, extensions;

create or replace function public.recommended_friends(
  p_limit int default 10
)
returns table (
  id            uuid,
  username      text,
  display_name  text,
  avatar_url    text,
  bio           text,
  mutual_count  int
)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  -- `AS friend_id` (no column list) is the same trick `visits_in_bounds`
  -- uses for `unnest(...) AS uid`: for a scalar set-returning function, the
  -- alias names the column too. A column-definition list would be rejected
  -- here — those are only for functions returning `record`, and
  -- `friend_ids` returns `setof uuid`.
  with mine as (
    select friend_id
    from public.friend_ids(auth.uid()) as friend_id
  ),
  -- Friends-of-friends, one row per (my friend, their friend) pair. A
  -- candidate shared by three of my friends contributes three rows here,
  -- which is what turns the later count(*) into the mutual-friend count.
  -- The function call is implicitly LATERAL: it may reference `m.friend_id`
  -- because `m` is an earlier item in the same FROM list.
  fof as (
    select candidate_id
    from mine m, public.friend_ids(m.friend_id) as candidate_id
  ),
  counted as (
    select candidate_id, count(*) as mutual_count
    from fof
    where candidate_id <> auth.uid()
      and candidate_id not in (select friend_id from mine)
    group by candidate_id
  )
  select
    p.id,
    p.username::text,
    p.display_name,
    p.avatar_url,
    p.bio,
    counted.mutual_count::int
  from counted
  join public.profiles p on p.id = counted.candidate_id
  where p.username is not null
    -- Excludes accepted, pending (either direction) and blocked in one shot —
    -- a friend-of-a-friend who already has a pending request with the caller
    -- belongs in Incoming/Sent, not in a second list underneath it.
    and not exists (
      select 1 from public.friendships f
      where least(f.requester_id, f.addressee_id)    = least(counted.candidate_id, auth.uid())
        and greatest(f.requester_id, f.addressee_id) = greatest(counted.candidate_id, auth.uid())
    )
  order by counted.mutual_count desc, coalesce(p.display_name, p.username::text)
  limit greatest(1, least(coalesce(p_limit, 10), 25));
$$;

comment on function public.recommended_friends(int) is
  'Friends-of-friends the caller is not already connected to, ranked by shared friend count. Empty when there is nothing to recommend.';

revoke all on function public.recommended_friends(int) from public;
grant execute on function public.recommended_friends(int) to authenticated;
