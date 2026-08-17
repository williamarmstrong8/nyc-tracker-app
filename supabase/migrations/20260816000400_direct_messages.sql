-- ============================================================================
-- 0816.0400 — Direct messages
-- ============================================================================
-- Friends stop being a directory and become a conversation. The Friends page
-- now opens a thread per friend instead of a profile, and the only thing you
-- can put in a thread is a place plus a note about it.
--
-- Three decisions here are load-bearing:
--
--   1. A conversation is a PAIR, stored ordered (`user_a < user_b`) with a
--      unique constraint — the same shape `friendships` uses. Two directed
--      inboxes would mean every read de-duplicates, and the "did a thread
--      already exist" question would have two answers.
--
--   2. `conversations` is never written by a client statement. Its two mutable
--      columns (`last_message_at`, the read cursors) are moved only by the
--      trigger and the RPC below, both SECURITY DEFINER. RLS is row-scoped and
--      cannot say "you may move your own cursor but not theirs"; a definer
--      function that reads `auth.uid()` itself can.
--
--   3. `message_details` is a SECURITY INVOKER view, not four more RPCs. The
--      join a message card needs (venue + the sender's photos of it) is the
--      same on every surface, and a view lets PostgREST paginate it directly
--      while RLS on `messages` still decides what comes back.
--
-- Privacy: `messages` is the second genuinely private table, after
-- `recommendations`. Everything else in this schema is world-readable to
-- authenticated users (see 0600_rls.sql); a DM is not.
--
-- All statements are idempotent.
-- ============================================================================

set search_path = public, extensions;


-- ----------------------------------------------------------------------------
-- 1. conversations — one row per unordered pair
-- ----------------------------------------------------------------------------
-- The pair is stored already ordered rather than ordered by an index
-- expression (which is how `friendships` does it). Both work; storing it
-- ordered is better here because the read cursors have to be addressed as
-- "mine" vs "theirs" on every read, and `case when user_a = auth.uid()` is only
-- correct if the column assignment is stable. With an expression index the
-- caller could sit in either column and that CASE would be a coin flip.
create table if not exists public.conversations (
  id              uuid primary key default gen_random_uuid(),
  user_a          uuid not null references public.profiles(id) on delete cascade,
  user_b          uuid not null references public.profiles(id) on delete cascade,

  created_at      timestamptz not null default now(),
  -- Denormalised from `messages` by the trigger below. It is the sort key for
  -- the thread list, and computing it with a lateral MAX per row would make the
  -- list's ORDER BY depend on a subquery it cannot use an index for.
  last_message_at timestamptz,

  -- Read cursors, one per side. A timestamp rather than a per-message read
  -- flag: unread is "anything after when I last looked", which is one
  -- comparison instead of a row per message per reader.
  a_last_read_at  timestamptz,
  b_last_read_at  timestamptz,

  constraint conversations_ordered check (user_a < user_b),
  constraint conversations_unique_pair unique (user_a, user_b)
);

comment on table public.conversations is
  'One direct-message thread per unordered pair of users, stored with user_a < user_b.';


-- ----------------------------------------------------------------------------
-- 2. messages
-- ----------------------------------------------------------------------------
-- `body` is required and `place_id` is not. That is the inverse of how the app
-- behaves today (the composer only sends place + note, never a bare note), and
-- it is deliberate: a note with no venue is a plain chat message, which this
-- table should be able to hold the day the product wants one. A venue with no
-- note is the thing worth preventing — it is a link with no reason attached,
-- and the whole point of sending a place here rather than through
-- `recommendations` is that you said something about it.
--
-- Both foreign keys are ON DELETE SET NULL. A message is a record of something
-- someone said; it must survive the venue being merged away or the sender
-- deleting the visit they were talking about, with the text intact.
create table if not exists public.messages (
  id              uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  sender_id       uuid not null references public.profiles(id)      on delete cascade,

  body            text not null,

  -- The venue being shared, and the sender's own visit to it when they picked
  -- one from their log. `visit_id` is what makes the card show their photos and
  -- their write-up rather than a generic venue card.
  place_id        uuid references public.places(id) on delete set null,
  visit_id        uuid references public.visits(id) on delete set null,

  created_at      timestamptz not null default now(),

  constraint messages_body_length
    check (char_length(btrim(body)) between 1 and 2000)
);

comment on table public.messages is
  'A direct message: a note, usually about a place the sender has been. Private to the two participants.';

-- Query: one thread, newest first, keyset-paginated on created_at.
create index if not exists messages_conversation_created_idx
  on public.messages (conversation_id, created_at desc);

-- Query: the unread count in `conversation_threads`, which filters
-- `sender_id <> me` inside one conversation.
create index if not exists messages_conversation_sender_idx
  on public.messages (conversation_id, sender_id);

-- Query: the thread list's sort, per side of the pair.
create index if not exists conversations_user_a_recent_idx
  on public.conversations (user_a, last_message_at desc);
create index if not exists conversations_user_b_recent_idx
  on public.conversations (user_b, last_message_at desc);


-- ----------------------------------------------------------------------------
-- 3. The conversation row is maintained by triggers, never by the client
-- ----------------------------------------------------------------------------
-- SECURITY DEFINER because `authenticated` has no UPDATE grant on
-- `conversations` at all (see the grants at the foot of this file). That is the
-- point: if the client could write these columns it could mark a thread read on
-- the other person's behalf, or backdate `last_message_at` to bury a thread.
--
-- Bumping the SENDER's own cursor here is what stops your own message counting
-- as unread to you. The alternative — excluding your own messages in every
-- unread query — works too, right up until a second surface forgets to.
create or replace function public.messages_bump_conversation()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.conversations c
     set last_message_at = new.created_at,
         a_last_read_at  = case when c.user_a = new.sender_id
                                then new.created_at else c.a_last_read_at end,
         b_last_read_at  = case when c.user_b = new.sender_id
                                then new.created_at else c.b_last_read_at end
   where c.id = new.conversation_id;

  return null;  -- AFTER trigger; the return value is ignored
end;
$$;

drop trigger if exists messages_bump_conversation_trg on public.messages;
create trigger messages_bump_conversation_trg
  after insert on public.messages
  for each row execute function public.messages_bump_conversation();

comment on function public.messages_bump_conversation() is
  'Keeps conversations.last_message_at current and marks the sender''s own message as already read by them.';


-- ----------------------------------------------------------------------------
-- 4. RLS
-- ----------------------------------------------------------------------------
alter table public.conversations enable row level security;
alter table public.messages      enable row level security;

-- conversations SELECT: participants only. Unlike `friendships`, there is no
-- world-readable case — that two people talk is itself private.
drop policy if exists conversations_select_parties on public.conversations;
create policy conversations_select_parties
  on public.conversations for select
  to authenticated
  using (auth.uid() in (user_a, user_b));

-- conversations INSERT: you may open a thread you are half of, with someone who
-- is actually your friend. The friendship check lives here rather than only in
-- `open_conversation` so that the guarantee survives anyone writing a second
-- way to create a thread.
drop policy if exists conversations_insert_by_friend on public.conversations;
create policy conversations_insert_by_friend
  on public.conversations for insert
  to authenticated
  with check (
    auth.uid() in (user_a, user_b)
    and public.are_friends(user_a, user_b)
  );

-- conversations UPDATE / DELETE: no policy, and no grant. Every mutation goes
-- through `messages_bump_conversation()` or `mark_conversation_read()`.
-- Deleting a thread is not a feature yet; when it is, it should be a per-side
-- hide (another cursor column), not a DELETE that destroys the other person's
-- copy of the conversation.

-- messages SELECT: participants of the parent conversation. Expressed against
-- `conversations` rather than duplicating the pair on `messages`, so there is
-- one place that decides who is in a thread.
drop policy if exists messages_select_parties on public.messages;
create policy messages_select_parties
  on public.messages for select
  to authenticated
  using (
    exists (
      select 1 from public.conversations c
      where c.id = messages.conversation_id
        and auth.uid() in (c.user_a, c.user_b)
    )
  );

-- messages INSERT: as yourself, into a thread you are in, while you are still
-- friends. The friendship re-check matters — a thread outlives an unfriend (the
-- history stays readable to both) but must not accept new messages after it.
drop policy if exists messages_insert_as_sender on public.messages;
create policy messages_insert_as_sender
  on public.messages for insert
  to authenticated
  with check (
    auth.uid() = sender_id
    and exists (
      select 1 from public.conversations c
      where c.id = messages.conversation_id
        and auth.uid() in (c.user_a, c.user_b)
        and public.are_friends(c.user_a, c.user_b)
    )
  );

-- messages UPDATE: nobody. A sent message is a record of what was said; an
-- editable one is a record of what someone currently claims they said.
-- (Absence of a policy = denied. The grant is revoked below as well, so a
-- future permissive policy can't quietly open it.)

-- messages DELETE: the sender may unsend their own. Not surfaced in the UI yet;
-- it exists because the alternative — a message that cannot be taken back —
-- is a support request waiting to happen, and adding the policy later would not
-- help anyone who already sent the wrong thing.
drop policy if exists messages_delete_by_sender on public.messages;
create policy messages_delete_by_sender
  on public.messages for delete
  to authenticated
  using (auth.uid() = sender_id);

-- Table privileges, spelled out rather than inherited. Supabase's newer
-- projects do not auto-expose freshly created public tables to the Data API
-- roles (see `auto_expose_new_tables` in config.toml), so an unstated grant
-- here is not "whatever the default is" — it is no access at all. Stating the
-- full set also makes the two omissions legible: no UPDATE anywhere, and no
-- DELETE on conversations.
revoke all on public.conversations from authenticated;
revoke all on public.messages      from authenticated;
grant  select, insert                 on public.conversations to authenticated;
grant  select, insert, delete         on public.messages      to authenticated;

revoke all on public.conversations from anon;
revoke all on public.messages      from anon;


-- ----------------------------------------------------------------------------
-- 5. open_conversation — find or create, idempotently
-- ----------------------------------------------------------------------------
-- Called every time a thread is opened, including the first time, so it has to
-- be cheap and it has to be safe to race with itself: tapping a friend on two
-- devices at once must not create two threads (the unique constraint) and must
-- not fail on the second one (the exception handler).
--
-- SECURITY INVOKER, matching `send_friend_request`: every step is something the
-- caller is already allowed to do, so the policies above are the enforcement
-- rather than a second copy of them living in here that can drift.
create or replace function public.open_conversation(p_other uuid)
returns uuid
language plpgsql
security invoker
set search_path = public, extensions
as $$
declare
  v_me uuid := auth.uid();
  v_a  uuid;
  v_b  uuid;
  v_id uuid;
begin
  if v_me is null then
    raise exception 'open_conversation: authentication required' using errcode = '28000';
  end if;

  if p_other is null then
    raise exception 'open_conversation: a recipient is required' using errcode = '22023';
  end if;

  if p_other = v_me then
    raise exception 'open_conversation: cannot open a conversation with yourself'
      using errcode = '22023';
  end if;

  -- Friends-only, checked here as well as in the INSERT policy so the caller
  -- gets a sentence instead of a policy violation on the common case.
  if not public.are_friends(v_me, p_other) then
    raise exception 'open_conversation: you can only message friends'
      using errcode = '42501';
  end if;

  v_a := least(v_me, p_other);
  v_b := greatest(v_me, p_other);

  select c.id into v_id
  from public.conversations c
  where c.user_a = v_a and c.user_b = v_b;

  if v_id is not null then
    return v_id;
  end if;

  -- Sub-block so a lost race rolls back to here rather than aborting the call.
  begin
    insert into public.conversations (user_a, user_b)
    values (v_a, v_b)
    returning id into v_id;
  exception
    when unique_violation then
      -- READ COMMITTED gives this statement a fresh snapshot, so the row that
      -- beat us to the unique index is visible now even though it wasn't when
      -- the INSERT began.
      select c.id into v_id
      from public.conversations c
      where c.user_a = v_a and c.user_b = v_b;
  end;

  return v_id;
end;
$$;

comment on function public.open_conversation(uuid) is
  'Returns the thread with another user, creating it on first use. Friends only; safe to call repeatedly and concurrently.';


-- ----------------------------------------------------------------------------
-- 6. message_details — the shape every message surface needs
-- ----------------------------------------------------------------------------
-- A view rather than a function so PostgREST can filter, order and keyset-
-- paginate it directly: the thread reads one page with `conversation_id=eq.…`
-- plus `created_at=lt.…`, which an RPC would have to re-implement as
-- parameters.
--
-- `security_invoker = true` is the whole reason this is safe. Without it the
-- view would run as its owner (postgres, which bypasses RLS) and every user
-- would read every DM in the database. With it, `messages_select_parties`
-- applies to the caller exactly as if they had queried the table.
--
-- Photos are inlined the same way `visits_in_bounds` inlines them, for the same
-- reason: the card draws one as soon as the row arrives, and a second request
-- per message would be a request per row on screen.
drop view if exists public.message_details cascade;
create view public.message_details
with (security_invoker = true)
as
  select
    m.id,
    m.conversation_id,
    m.sender_id,
    m.body,
    m.created_at,

    pr.username::text as username,
    pr.display_name,
    pr.avatar_url,

    m.place_id,
    pl.name           as place_name,
    pl.category       as place_category,
    pl.neighborhood,
    pl.street_address,
    pl.latitude,
    pl.longitude,

    m.visit_id,
    v.title           as visit_title,
    v.tags            as visit_tags,
    v.rating_label    as visit_rating_label,

    -- The shared visit's photos, falling back to the sender's most recent visit
    -- at the same venue. The fallback covers two real cases: a message whose
    -- visit was soft-deleted, and a place shared from the map rather than from
    -- the sender's own log.
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
        where ph.visit_id = coalesce(
          v.id,
          (
            select v2.id
            from public.visits v2
            where v2.user_id    = m.sender_id
              and v2.place_id   = m.place_id
              and v2.kind       = 'visited'
              and v2.deleted_at is null
            order by v2.visited_at desc
            limit 1
          )
        )
      ),
      '[]'::jsonb
    ) as photos

  from public.messages m
  join public.profiles pr on pr.id = m.sender_id
  left join public.places pl on pl.id = m.place_id
  -- Soft-deleted visits drop out of the join, which is what sends the photo
  -- lookup down the fallback branch above.
  left join public.visits v
    on v.id = m.visit_id
   and v.deleted_at is null;

comment on view public.message_details is
  'Messages with their venue, the sender, and the sender''s photos of that venue. SECURITY INVOKER — RLS on messages still applies.';

revoke all    on public.message_details from public;
revoke all    on public.message_details from anon;
grant  select on public.message_details to authenticated;


-- ----------------------------------------------------------------------------
-- 7. send_message
-- ----------------------------------------------------------------------------
-- Returns the composed row, not just an id: the client renders the sent message
-- immediately, and a bare id would mean a second round trip to find out what
-- the thing it just sent looks like.
--
-- SECURITY INVOKER, so `messages_insert_as_sender` is what actually decides
-- whether this write lands. The checks below are for message quality, not
-- permission — with one exception, the `visit_id` ownership check, which RLS
-- genuinely cannot express: nothing on `messages` ties `visit_id` to
-- `sender_id`, so without this you could attach someone else's write-up to your
-- own message and it would render as yours.
create or replace function public.send_message(
  p_conversation uuid,
  p_body         text,
  p_place        uuid default null,
  p_visit        uuid default null
)
returns setof public.message_details
language plpgsql
security invoker
set search_path = public, extensions
as $$
declare
  v_me    uuid := auth.uid();
  v_body  text := nullif(btrim(coalesce(p_body, '')), '');
  v_place uuid := p_place;
  v_id    uuid;
begin
  if v_me is null then
    raise exception 'send_message: authentication required' using errcode = '28000';
  end if;

  if p_conversation is null then
    raise exception 'send_message: a conversation is required' using errcode = '22023';
  end if;

  -- The CHECK constraint would catch this, but as a constraint violation the
  -- client has to pattern-match on a Postgres error string to say something
  -- useful. The composer already requires a note; this is the backstop.
  if v_body is null then
    raise exception 'send_message: a message is required' using errcode = '22023';
  end if;

  if p_visit is not null then
    if not exists (
      select 1 from public.visits v
      where v.id = p_visit and v.user_id = v_me and v.deleted_at is null
    ) then
      raise exception 'send_message: you can only share your own visits'
        using errcode = '42501';
    end if;

    -- Derive the venue from the visit when the caller didn't send one. Keeps
    -- the two columns from disagreeing about which place is being shared.
    if v_place is null then
      select v.place_id into v_place from public.visits v where v.id = p_visit;
    end if;
  end if;

  insert into public.messages (conversation_id, sender_id, body, place_id, visit_id)
  values (p_conversation, v_me, v_body, v_place, p_visit)
  returning id into v_id;

  return query
    select * from public.message_details d where d.id = v_id;
end;
$$;

comment on function public.send_message(uuid, text, uuid, uuid) is
  'Sends one message into a thread and returns it in the same shape reads use.';


-- ----------------------------------------------------------------------------
-- 8. conversation_threads — the friends list's previews, and the badge
-- ----------------------------------------------------------------------------
-- One call backs three things: the last-message line under each friend, the
-- per-thread unread dot, and the tab badge. Splitting them would be three
-- queries over the same rows and a badge that can disagree with the list it is
-- counting.
--
-- Only threads that exist come back. A friend you have never messaged has no
-- row here, and the friends list falls back to their handle — which is why this
-- is not a join against the friend graph: the graph already knows who your
-- friends are, and joining would make an empty inbox cost a scan of it.
create or replace function public.conversation_threads()
returns table (
  conversation_id         uuid,
  user_id                 uuid,
  username                text,
  display_name            text,
  avatar_url              text,
  created_at              timestamptz,
  last_message_at         timestamptz,
  last_message_body       text,
  last_message_sender_id  uuid,
  last_message_place_name text,
  unread_count            int
)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select
    c.id,
    p.id,
    p.username::text,
    p.display_name,
    p.avatar_url,
    c.created_at,
    c.last_message_at,
    lm.body,
    lm.sender_id,
    lpl.name,
    (
      select count(*)::int
      from public.messages m
      where m.conversation_id = c.id
        and m.sender_id <> auth.uid()
        and m.created_at > coalesce(
              case when c.user_a = auth.uid() then c.a_last_read_at
                   else c.b_last_read_at end,
              '-infinity'::timestamptz
            )
    )
  from public.conversations c
  join public.profiles p
    on p.id = case when c.user_a = auth.uid() then c.user_b else c.user_a end
  left join lateral (
    select m.body, m.sender_id, m.place_id
    from public.messages m
    where m.conversation_id = c.id
    order by m.created_at desc
    limit 1
  ) lm on true
  left join public.places lpl on lpl.id = lm.place_id
  where auth.uid() in (c.user_a, c.user_b)
  order by c.last_message_at desc nulls last;
$$;

comment on function public.conversation_threads() is
  'Every thread the caller is in, newest first, with a preview of the last message and an unread count.';


-- ----------------------------------------------------------------------------
-- 9. mark_conversation_read
-- ----------------------------------------------------------------------------
-- SECURITY DEFINER, and therefore the participant check below is not decoration
-- — it is the only thing standing between a caller and any conversation row in
-- the table. It is written before the UPDATE and the UPDATE is keyed on the
-- same id, so there is no path through this function that touches a thread the
-- caller is not in.
--
-- Definer rather than a column-level grant because "you may set your own cursor
-- but not theirs" is a column-per-caller rule, and grants are per-column for
-- everyone. Here `auth.uid()` picks the column.
create or replace function public.mark_conversation_read(p_conversation uuid)
returns timestamptz
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me   uuid := auth.uid();
  v_now  timestamptz := now();
  v_a    uuid;
  v_b    uuid;
begin
  if v_me is null then
    raise exception 'mark_conversation_read: authentication required' using errcode = '28000';
  end if;

  select c.user_a, c.user_b into v_a, v_b
  from public.conversations c
  where c.id = p_conversation;

  -- No such thread. Returning null rather than raising: the usual cause is a
  -- thread that was open when the account on the other end went away, and an
  -- alert about a read receipt would be noise.
  if v_a is null then
    return null;
  end if;

  if v_me not in (v_a, v_b) then
    raise exception 'mark_conversation_read: not a participant in this conversation'
      using errcode = '42501';
  end if;

  update public.conversations c
     set a_last_read_at = case when c.user_a = v_me then v_now else c.a_last_read_at end,
         b_last_read_at = case when c.user_b = v_me then v_now else c.b_last_read_at end
   where c.id = p_conversation;

  return v_now;
end;
$$;

comment on function public.mark_conversation_read(uuid) is
  'Moves the caller''s own read cursor on one thread to now(). Participants only.';


-- ----------------------------------------------------------------------------
-- 10. Realtime
-- ----------------------------------------------------------------------------
-- Adding `messages` to the publication is what lets a thread update while it is
-- open instead of on the next pull. Realtime evaluates the SELECT policy per
-- subscriber before delivering a change, so a client subscribed to the whole
-- table still only receives rows `messages_select_parties` would have returned
-- — which is why the app subscribes without a filter and lets the server sort
-- out whose messages are whose.
--
-- `conversations` is deliberately NOT published. Its interesting change is
-- `last_message_at`, which is a consequence of a message insert the subscriber
-- is already being told about.
--
-- Replica identity stays at the default (primary key): inserts carry their full
-- row regardless, and the app has no use for the old row on a delete.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'public'
        and tablename = 'messages'
    ) then
      alter publication supabase_realtime add table public.messages;
    end if;
  end if;
end $$;


-- ----------------------------------------------------------------------------
-- Grants
-- ----------------------------------------------------------------------------
-- Same pattern as the other migrations: nothing for `public` or `anon`, execute
-- for `authenticated`. The two SECURITY DEFINER functions are granted too —
-- they are meant to be called by clients, and each one re-derives the caller
-- from `auth.uid()` rather than trusting a parameter.
revoke all on function public.open_conversation(uuid)                  from public;
revoke all on function public.send_message(uuid, text, uuid, uuid)     from public;
revoke all on function public.conversation_threads()                   from public;
revoke all on function public.mark_conversation_read(uuid)             from public;
revoke all on function public.messages_bump_conversation()             from public;

grant execute on function public.open_conversation(uuid)               to authenticated;
grant execute on function public.send_message(uuid, text, uuid, uuid)  to authenticated;
grant execute on function public.conversation_threads()                to authenticated;
grant execute on function public.mark_conversation_read(uuid)          to authenticated;


-- ----------------------------------------------------------------------------
-- A note on how this relates to `recommendations`
-- ----------------------------------------------------------------------------
-- These two features both move a place from one person to another and they are
-- not duplicates.
--
--   * A recommendation is a POINTER. It lands on the recipient's wishlist,
--     dedupes per (sender, recipient, place) so it cannot be sent twice, and is
--     dismissable — it is a task the recipient works through.
--   * A message is a CONVERSATION TURN. Sending the same place twice is
--     allowed, because the second time you had something else to say about it.
--     Nothing is dismissed, and nothing lands on a list.
--
-- Deliberately not wired together: sending a place in chat does NOT create a
-- recommendation or a wishlist row. If it did, every "we should go here" would
-- silently add a chore to the other person's list, and the wishlist would stop
-- meaning "places I chose to keep".
