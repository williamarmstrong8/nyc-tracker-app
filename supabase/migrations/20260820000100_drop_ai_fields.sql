-- ============================================================================
-- 0820.0100 — drop the AI-enrichment columns
-- ============================================================================
-- The on-device enrichment step is gone from the client (see CLAUDE.md): there
-- is no more model turning a transcript into a summary, lifting a pull quote
-- out of it, or asking a four-point "would you go back" question. The app now
-- writes exactly one field for the body text (`summary`, holding what the
-- client calls `Visit.note`) and a two-case liked/not-liked verdict.
--
-- `transcript`, `top_quote` and `return_intent` have been dead weight since
-- the client started sending `encodeNil` for all three — this just makes that
-- permanent and stops paying for three columns, a CHECK constraint, and their
-- copies across four `returns table` RPCs.
--
-- `rating_label` stays, but its CHECK shrinks to the two values the client can
-- still produce. `loved`/`fine` were the other two of the old four-point scale,
-- and the client's existing loose parser (`Rating.from(loose:)`) is the source
-- of truth for how they already read: `loved` contains "love" and resolves to
-- `.liked`; `fine` matches none of the parser's keywords and resolves to no
-- rating at all (`nil`). The UPDATE below makes both of those permanent in the
-- column itself — `loved` -> `liked`, `fine` -> `NULL` — before the CHECK is
-- tightened, so no row's displayed verdict changes and the migration can't
-- fail on old data.
-- ============================================================================

set search_path = public, extensions;


-- ----------------------------------------------------------------------------
-- 1. Normalise any rows still carrying the retired rating labels
-- ----------------------------------------------------------------------------
-- Same mapping `Rating.from(loose:)` already applies on read, done once here so
-- the tightened CHECK below has nothing left to reject.
update public.visits
set rating_label = 'liked'
where rating_label = 'loved';

update public.visits
set rating_label = null
where rating_label = 'fine';


-- ----------------------------------------------------------------------------
-- 2. Tighten the rating_label CHECK to the two live values
-- ----------------------------------------------------------------------------
alter table public.visits
  drop constraint if exists visits_rating_label_valid;

alter table public.visits
  add constraint visits_rating_label_valid
  check (rating_label is null or rating_label in ('liked', 'no'));


-- ----------------------------------------------------------------------------
-- 3. Drop the dead columns
-- ----------------------------------------------------------------------------
-- `return_intent`'s CHECK (visits_return_intent_valid) goes with it — Postgres
-- drops a constraint automatically when every column it references is dropped.
alter table public.visits drop column if exists transcript;
alter table public.visits drop column if exists top_quote;
alter table public.visits drop column if exists return_intent;


-- ----------------------------------------------------------------------------
-- 4. Recreate the visit-returning RPCs without the three columns
-- ----------------------------------------------------------------------------
-- DROP + CREATE, not CREATE OR REPLACE: the RETURNS TABLE shape changed, which
-- Postgres will not let a REPLACE do. Same reasoning and order as
-- 20260818000100_visit_tags.sql, which added a column here for the same
-- structural reason.
drop function if exists public.friend_feed(timestamptz, uuid, int);
drop function if exists public.tagged_visits(uuid, int);
drop function if exists public.user_visits(uuid, int);
drop function if exists public.visits_in_bounds(
  double precision, double precision, double precision, double precision, uuid[], int
);


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
  tags           text[],
  rating_label   text,
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
    v.tags,
    v.rating_label,
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
  tags           text[],
  rating_label   text,
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


create or replace function public.tagged_visits(
  p_user  uuid,
  p_limit int default 100
)
returns table (
  visit_id       uuid,
  visited_at     timestamptz,
  title          text,
  summary        text,
  tags           text[],
  rating_label   text,
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
    v.tags,
    v.rating_label,
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
  tags                text[],
  rating_label        text,
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
    v.tags,
    v.rating_label,
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
-- The four recreated functions lost their grants when they were dropped.
revoke all on function public.tagged_visits(uuid, int) from public;
revoke all on function public.user_visits(uuid, int) from public;
revoke all on function public.friend_feed(timestamptz, uuid, int) from public;
revoke all on function public.visits_in_bounds(
  double precision, double precision, double precision, double precision, uuid[], int
) from public;

grant execute on function public.tagged_visits(uuid, int)              to authenticated;
grant execute on function public.user_visits(uuid, int)                to authenticated;
grant execute on function public.friend_feed(timestamptz, uuid, int)   to authenticated;
grant execute on function public.visits_in_bounds(
  double precision, double precision, double precision, double precision, uuid[], int
) to authenticated;
