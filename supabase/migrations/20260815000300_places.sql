-- ============================================================================
-- 0300 — places (canonical venue entities) + find_or_create_place()
-- ============================================================================
-- This is the load-bearing table. Two users photographing the same restaurant
-- MUST land on one row here. "3 friends have been here", friend map layers, and
-- recommendations are all joins through places.id — if dedupe is wrong, every
-- one of those features is quietly wrong too.
-- ============================================================================

set search_path = public, extensions;

create table if not exists public.places (
  id              uuid primary key default gen_random_uuid(),

  -- MKMapItem.identifier. Primary dedupe key when present.
  --
  -- Nullable on purpose, and this is not an edge case — it is common:
  --   * user-dropped pins have no identifier
  --   * some POIs simply don't carry one
  --   * reverse-geocoded coordinates with no matching POI return nil
  -- Apple also does not contractually guarantee the identifier is stable across
  -- time, which is the second reason we keep a coordinate/name fallback key
  -- rather than treating this as the only identity.
  mapkit_id       text unique,

  name            text not null,

  -- Fallback dedupe key, half 1. Generated so it can never drift from `name`.
  normalized_name text not null
    generated always as (public.app_normalize_name(name)) stored,

  street_address  text,
  locality        text,        -- city
  admin_area      text,        -- state / region
  country         text,
  postal_code     text,

  latitude        double precision not null,
  longitude       double precision not null,

  -- Fallback dedupe key, half 2. ~150m cell. Also serves proximity lookups.
  geohash7        text not null
    generated always as (public.app_geohash(latitude, longitude, 7)) stored,

  category        text,        -- MapKit point-of-interest category, e.g. "restaurant"
  phone           text,
  website_url     text,

  created_at      timestamptz not null default now(),
  created_by      uuid references public.profiles(id) on delete set null,

  constraint places_latitude_range  check (latitude  between  -90 and  90),
  constraint places_longitude_range check (longitude between -180 and 180),
  constraint places_name_not_blank  check (btrim(name) <> '')
);

comment on table public.places is
  'Canonical venue. Deduped on mapkit_id when present, else on (normalized_name, geohash7).';

-- Tier 2 of the dedupe strategy. Partial: only rows WITHOUT a MapKit identifier
-- participate, so two genuinely distinct MapKit venues that happen to share a
-- name and a geohash cell (a chain with two locations on the same block) are
-- still allowed to coexist.
create unique index if not exists places_name_geohash_unique_idx
  on public.places (normalized_name, geohash7)
  where mapkit_id is null;


-- ----------------------------------------------------------------------------
-- Indexes
-- ----------------------------------------------------------------------------

-- Query: map viewport fetch —
--   `where latitude between $1 and $2 and longitude between $3 and $4`
-- A plain btree on (latitude, longitude) only ranges efficiently on latitude,
-- but that alone cuts a citywide table to a thin band, and the app's viewport is
-- small. Revisit with PostGIS + GiST if place count ever gets large.
create index if not exists places_lat_lng_idx
  on public.places (latitude, longitude);

-- Query: proximity / fallback matching inside find_or_create_place(), and
-- "places near this cell" lookups.
create index if not exists places_geohash7_idx
  on public.places (geohash7);


-- ----------------------------------------------------------------------------
-- find_or_create_place()
-- ----------------------------------------------------------------------------
-- Call this instead of doing match-then-insert from the client. Two users
-- checking in to the same restaurant at the same moment WILL race a client-side
-- "select, then insert if missing" and create duplicate rows. The whole point of
-- this function is that the match and the insert are one atomic statement.
--
-- Two-tier match:
--   1. mapkit_id present  -> upsert on the unique index over mapkit_id
--   2. mapkit_id is null  -> upsert on the partial unique index over
--                            (normalized_name, geohash7)
--
-- Backfill rule: when a row already exists and the incoming payload carries data
-- the stored row is missing (we now have a phone number, it doesn't), fill the
-- NULLs. Never overwrite a non-null stored value — the first writer's data is
-- assumed at least as good, and silent churn on a shared row is hard to debug.
-- `coalesce(places.<col>, excluded.<col>)` encodes exactly that.
--
-- SECURITY DEFINER so it can insert into places while the table's RLS grants no
-- INSERT to anyone. Callers get a place id back and nothing else.
create or replace function public.find_or_create_place(
  p_mapkit_id      text,
  p_name           text,
  p_latitude       double precision,
  p_longitude      double precision,
  p_street_address text default null,
  p_locality       text default null,
  p_admin_area     text default null,
  p_country        text default null,
  p_postal_code    text default null,
  p_category       text default null,
  p_phone          text default null,
  p_website_url    text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_id       uuid;
  v_mapkit   text := nullif(btrim(coalesce(p_mapkit_id, '')), '');
  v_name     text := btrim(coalesce(p_name, ''));
  v_caller   uuid := auth.uid();
begin
  if v_caller is null then
    raise exception 'find_or_create_place: authentication required'
      using errcode = '28000';
  end if;

  if v_name = '' then
    raise exception 'find_or_create_place: name is required'
      using errcode = '22023';
  end if;

  if p_latitude is null or p_longitude is null then
    raise exception 'find_or_create_place: latitude and longitude are required'
      using errcode = '22023';
  end if;

  -- ---- Tier 1: MapKit identifier ------------------------------------------
  if v_mapkit is not null then
    insert into public.places (
      mapkit_id, name, latitude, longitude,
      street_address, locality, admin_area, country, postal_code,
      category, phone, website_url, created_by
    )
    values (
      v_mapkit, v_name, p_latitude, p_longitude,
      p_street_address, p_locality, p_admin_area, p_country, p_postal_code,
      p_category, p_phone, p_website_url, v_caller
    )
    on conflict (mapkit_id) do update set
      street_address = coalesce(places.street_address, excluded.street_address),
      locality       = coalesce(places.locality,       excluded.locality),
      admin_area     = coalesce(places.admin_area,     excluded.admin_area),
      country        = coalesce(places.country,        excluded.country),
      postal_code    = coalesce(places.postal_code,    excluded.postal_code),
      category       = coalesce(places.category,       excluded.category),
      phone          = coalesce(places.phone,          excluded.phone),
      website_url    = coalesce(places.website_url,    excluded.website_url)
    returning id into v_id;

    return v_id;
  end if;

  -- ---- Tier 2: (normalized_name, geohash cell) -----------------------------
  -- Look first, including rows that DO have a mapkit_id. The partial unique
  -- index below can't see those rows, so without this lookup a user whose device
  -- returned nil for a venue another user resolved with a MapKit ID would create
  -- a duplicate. This SELECT is best-effort (it can lose a race); the upsert
  -- underneath is the correctness guarantee.
  select p.id into v_id
  from public.places p
  where p.normalized_name = public.app_normalize_name(v_name)
    and p.geohash7 = public.app_geohash(p_latitude, p_longitude, 7)
  limit 1;

  if v_id is not null then
    update public.places set
      street_address = coalesce(street_address, p_street_address),
      locality       = coalesce(locality,       p_locality),
      admin_area     = coalesce(admin_area,     p_admin_area),
      country        = coalesce(country,        p_country),
      postal_code    = coalesce(postal_code,    p_postal_code),
      category       = coalesce(category,       p_category),
      phone          = coalesce(phone,          p_phone),
      website_url    = coalesce(website_url,    p_website_url)
    where id = v_id;

    return v_id;
  end if;

  insert into public.places (
    mapkit_id, name, latitude, longitude,
    street_address, locality, admin_area, country, postal_code,
    category, phone, website_url, created_by
  )
  values (
    null, v_name, p_latitude, p_longitude,
    p_street_address, p_locality, p_admin_area, p_country, p_postal_code,
    p_category, p_phone, p_website_url, v_caller
  )
  on conflict (normalized_name, geohash7) where mapkit_id is null do update set
    street_address = coalesce(places.street_address, excluded.street_address),
    locality       = coalesce(places.locality,       excluded.locality),
    admin_area     = coalesce(places.admin_area,     excluded.admin_area),
    country        = coalesce(places.country,        excluded.country),
    postal_code    = coalesce(places.postal_code,    excluded.postal_code),
    category       = coalesce(places.category,       excluded.category),
    phone          = coalesce(places.phone,          excluded.phone),
    website_url    = coalesce(places.website_url,    excluded.website_url)
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.find_or_create_place(
  text, text, double precision, double precision,
  text, text, text, text, text, text, text, text
) from public;

grant execute on function public.find_or_create_place(
  text, text, double precision, double precision,
  text, text, text, text, text, text, text, text
) to authenticated;
