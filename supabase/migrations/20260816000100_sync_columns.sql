-- ============================================================================
-- 0816.0100 — Columns the sync layer needs
-- ============================================================================
-- This is the first migration written while actually moving app data across the
-- wire, and it is where the previous task's schema met the app's real model.
-- Every column below exists because something in the client had nowhere to go.
--
-- The four groups, and why each one is here:
--
--   1. DELETIONS (`visits.deleted_at`)
--      Incremental pull uses a `updated_at > lastPulledAt` watermark. A row
--      deleted on another device does not appear in that result set — it is
--      absent, and absence is indistinguishable from "unchanged". Without a
--      tombstone the local copy lingers forever on every other device. Soft
--      delete makes a deletion just another update, which the watermark already
--      handles. The alternative (a periodic full ID reconcile) costs a full
--      table scan on every device on a timer to catch an event that is rare;
--      one nullable timestamp is cheaper and exact.
--
--   2. FIELDS THE CLIENT ALREADY HAD AND THE SCHEMA DID NOT
--      `title`, `top_quote`, `rating_label`, `return_intent`, `kind`.
--      These are not new features — they are columns in the SwiftData model
--      today, shown in the write-up UI today. Without them, "delete the app,
--      reinstall, sign in" silently returns a degraded entry: no title, no pull
--      quote, no rating, and every want-to-try bookmark restored as a visit.
--
--   3. `places.neighborhood`
--      `places.locality` is the *city* ("New York"). The app's map callouts and
--      the "Top neighborhoods" profile stat want "West Village". CLPlacemark
--      gives us both and they are different fields; storing only locality makes
--      that whole stat read "New York, 47".
--
--   4. `visit_photos.thumb_path`
--      Separate thumbnail objects — see the comment on the column.
--
-- All statements are idempotent.
-- ============================================================================

set search_path = public, extensions;


-- ----------------------------------------------------------------------------
-- 1. Soft delete
-- ----------------------------------------------------------------------------

alter table public.visits
  add column if not exists deleted_at timestamptz;

comment on column public.visits.deleted_at is
  'Tombstone. Non-null means deleted. Set instead of DELETE so that an incremental '
  'pull (updated_at > watermark) carries the deletion to other devices.';

-- Every read path must filter this out, so index only the live rows: the partial
-- index is smaller and it is what `where deleted_at is null` will actually use.
create index if not exists visits_user_live_visited_at_idx
  on public.visits (user_id, visited_at desc)
  where deleted_at is null;

-- Query: the incremental pull itself — `where user_id = $1 and updated_at > $2`.
-- Deliberately NOT partial: the pull must see tombstones, that is the point.
create index if not exists visits_user_updated_at_idx
  on public.visits (user_id, updated_at);


-- ----------------------------------------------------------------------------
-- 2. Client fields that had nowhere to go
-- ----------------------------------------------------------------------------

-- The venue's name lives on `places.name` and is shared between users. `title` is
-- this user's heading for their own entry — pre-filled from the venue but freely
-- editable in the write-up, and routinely edited ("Katz's" -> "Katz's, 2am").
-- Putting the edit on places.name would rename the venue for everyone.
alter table public.visits
  add column if not exists title text;

-- The pull quote the on-device model lifts out of the transcript. Derived from
-- `transcript`, but not recomputable from it — enrichment is non-deterministic
-- and the model that produced it may not be the model installed at restore time.
alter table public.visits
  add column if not exists top_quote text;

-- The app's rating is a four-case enum (loved / liked / fine / no), not a number.
--
-- `visits.rating numeric(3,1)` already exists and is documented as a placeholder
-- for a future Beli-style 0-10 ranking. Those are two different things: this one
-- is what the user tapped, that one is a position derived from pairwise
-- comparisons across the whole list. Encoding the enum as 10/7.5/5/2.5 to reuse
-- the column would be lossy in one direction and meaningless in the other, and
-- the day the ranking feature lands it would have to be untangled from real
-- user input. Two columns, two meanings.
alter table public.visits
  add column if not exists rating_label text;

do $$
begin
  alter table public.visits
    add constraint visits_rating_label_valid
    check (rating_label is null or rating_label in ('loved', 'liked', 'fine', 'no'));
exception
  when duplicate_object then null;
end $$;

alter table public.visits
  add column if not exists return_intent text;

do $$
begin
  alter table public.visits
    add constraint visits_return_intent_valid
    check (return_intent is null or return_intent in
      ('immediately', 'whenNearby', 'ifSuggested', 'never'));
exception
  when duplicate_object then null;
end $$;

-- ---- kind: the want-to-try problem -----------------------------------------
--
-- `wishlist_items` already exists and looks like the right home for a
-- "want to try" entry. It is not, and this is the most consequential thing the
-- first sync pass turned up.
--
-- In the app, a want-to-try is captured through most of the same flow as a
-- visit: it can carry photos, a voice transcript, an AI summary, tags, and a
-- user-edited title. `wishlist_items` is (user_id, place_id, source) — it can
-- hold none of that. Routing want-to-try entries there would mean a reinstall
-- restores them as bare pins with the photos and notes gone.
--
-- So `visits.kind` it is, and `wishlist_items` keeps its actual job: the
-- lightweight "someone recommended this to me" row that the social features in
-- the next task create. The two are different objects that happen to share a
-- word. A want-to-try with three photos and a voice note is an entry the user
-- authored; a wishlist item is a pointer someone handed them.
--
-- Default 'visited' so existing rows — all of which are real visits — are
-- correct without a backfill.
alter table public.visits
  add column if not exists kind text not null default 'visited';

do $$
begin
  alter table public.visits
    add constraint visits_kind_valid
    check (kind in ('visited', 'wantToTry'));
exception
  when duplicate_object then null;
end $$;

comment on column public.visits.kind is
  'visited | wantToTry. A wantToTry is a user-authored entry (photos, transcript, '
  'tags) — distinct from wishlist_items, which is a pointer created by a '
  'recommendation and carries no content of its own.';

-- Query: map and list both filter by kind on top of the user scope.
create index if not exists visits_user_kind_idx
  on public.visits (user_id, kind)
  where deleted_at is null;


-- ----------------------------------------------------------------------------
-- 3. places.neighborhood
-- ----------------------------------------------------------------------------
-- CLPlacemark.subLocality. `locality` is the city and is already stored; these
-- are different fields and the app displays the narrower one.
alter table public.places
  add column if not exists neighborhood text;

comment on column public.places.neighborhood is
  'Sub-locality — "West Village", not "New York". locality holds the city.';


-- ----------------------------------------------------------------------------
-- 4. visit_photos.thumb_path
-- ----------------------------------------------------------------------------
-- A separate ~400px object per photo, uploaded alongside the 2048px one.
--
-- The alternative is deriving thumbnails on device from the cached full image,
-- which costs nothing extra in storage. It was rejected because of what a fresh
-- install feels like: derivation requires the full image FIRST, so a returning
-- user with 100 visits x 3 photos must pull ~300 x 400 KB = 120 MB before the
-- map and list stop showing grey boxes. With separate thumbs the same screens
-- fill from 300 x ~20 KB = 6 MB — seconds instead of minutes, and it degrades
-- gracefully on cellular. Full images then load lazily, only for the entry
-- actually opened.
--
-- The cost is ~5% more bytes stored and one more object per photo to upload and
-- to clean up on delete. That is a good trade at any scale this app will see;
-- the derive-on-device argument only starts winning when storage cost dominates
-- and users rarely reinstall, which is the opposite of this situation.
--
-- Nullable: rows written before this column existed, and any photo whose thumb
-- upload failed while the full-size one succeeded, simply fall back to the full
-- image. A missing thumb is a slow render, not a broken one.
alter table public.visit_photos
  add column if not exists thumb_path text;

comment on column public.visit_photos.thumb_path is
  'Object path of the ~400px thumbnail, or null to fall back to storage_path.';


-- ----------------------------------------------------------------------------
-- 5. find_or_create_place() — add p_neighborhood
-- ----------------------------------------------------------------------------
-- Postgres identifies functions by argument list, so adding a parameter creates
-- a SECOND function rather than replacing the first. The old 12-arg version has
-- to be dropped explicitly or both remain callable and PostgREST picks between
-- them by the keys the client happens to send — which would silently drop the
-- neighborhood for any caller that got routed to the old one.
drop function if exists public.find_or_create_place(
  text, text, double precision, double precision,
  text, text, text, text, text, text, text, text
);

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
  p_website_url    text default null,
  p_neighborhood   text default null
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
      category, phone, website_url, neighborhood, created_by
    )
    values (
      v_mapkit, v_name, p_latitude, p_longitude,
      p_street_address, p_locality, p_admin_area, p_country, p_postal_code,
      p_category, p_phone, p_website_url, p_neighborhood, v_caller
    )
    on conflict (mapkit_id) do update set
      street_address = coalesce(places.street_address, excluded.street_address),
      locality       = coalesce(places.locality,       excluded.locality),
      admin_area     = coalesce(places.admin_area,     excluded.admin_area),
      country        = coalesce(places.country,        excluded.country),
      postal_code    = coalesce(places.postal_code,    excluded.postal_code),
      category       = coalesce(places.category,       excluded.category),
      phone          = coalesce(places.phone,          excluded.phone),
      website_url    = coalesce(places.website_url,    excluded.website_url),
      neighborhood   = coalesce(places.neighborhood,   excluded.neighborhood)
    returning id into v_id;

    return v_id;
  end if;

  -- ---- Tier 2: (normalized_name, geohash cell) -----------------------------
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
      website_url    = coalesce(website_url,    p_website_url),
      neighborhood   = coalesce(neighborhood,   p_neighborhood)
    where id = v_id;

    return v_id;
  end if;

  insert into public.places (
    mapkit_id, name, latitude, longitude,
    street_address, locality, admin_area, country, postal_code,
    category, phone, website_url, neighborhood, created_by
  )
  values (
    null, v_name, p_latitude, p_longitude,
    p_street_address, p_locality, p_admin_area, p_country, p_postal_code,
    p_category, p_phone, p_website_url, p_neighborhood, v_caller
  )
  on conflict (normalized_name, geohash7) where mapkit_id is null do update set
    street_address = coalesce(places.street_address, excluded.street_address),
    locality       = coalesce(places.locality,       excluded.locality),
    admin_area     = coalesce(places.admin_area,     excluded.admin_area),
    country        = coalesce(places.country,        excluded.country),
    postal_code    = coalesce(places.postal_code,    excluded.postal_code),
    category       = coalesce(places.category,       excluded.category),
    phone          = coalesce(places.phone,          excluded.phone),
    website_url    = coalesce(places.website_url,    excluded.website_url),
    neighborhood   = coalesce(places.neighborhood,   excluded.neighborhood)
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.find_or_create_place(
  text, text, double precision, double precision,
  text, text, text, text, text, text, text, text, text
) from public;

grant execute on function public.find_or_create_place(
  text, text, double precision, double precision,
  text, text, text, text, text, text, text, text, text
) to authenticated;


-- ----------------------------------------------------------------------------
-- 6. RLS: keep tombstones writable, keep hard DELETE available
-- ----------------------------------------------------------------------------
-- Soft delete is an UPDATE, and `visits_update_own` already covers it: the row
-- stays owned by the same user, so the USING and WITH CHECK both pass. Nothing
-- to add.
--
-- `visits_delete_own` is intentionally left in place. The client never calls it
-- (it writes deleted_at instead), but the delete-account Edge Function and any
-- future tombstone reaper both need it. A reaper that hard-deletes rows whose
-- deleted_at is older than the longest plausible offline period is the natural
-- follow-up; it is not written here because choosing that window needs a real
-- sense of how long a device stays offline, and getting it wrong resurrects
-- deleted visits on a device that was away too long.
