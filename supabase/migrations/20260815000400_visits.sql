-- ============================================================================
-- 0400 — visits + visit_photos
-- ============================================================================
-- A `visit` is one user's personal experience at a `place`. Keeping them split is
-- the whole point of the places table: the venue is shared and canonical, the
-- experience is per-user and unshared.
-- ============================================================================

set search_path = public, extensions;

create table if not exists public.visits (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles(id) on delete cascade,
  place_id    uuid not null references public.places(id)   on delete cascade,

  visited_at  timestamptz not null,

  -- Raw voice-memo transcription, verbatim. The audio file itself is discarded
  -- after transcription and never uploaded — this text is the only record of it.
  transcript  text,

  -- On-device AI write-up derived from the transcript. Kept separate so the
  -- transcript is never clobbered by re-running enrichment.
  summary     text,

  tags        text[] not null default '{}',
  note        text,

  -- Unused today. Added now because a Beli-style ranking is the obvious next
  -- feature and a nullable numeric column costs nothing, whereas an ALTER on a
  -- populated table later costs a migration + a client release.
  rating      numeric(3,1),

  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),

  constraint visits_rating_range check (rating is null or rating between 0 and 10)
);

-- No unique constraint on (user_id, place_id): revisiting your favourite bar is
-- normal and each visit is its own row with its own transcript and photos.

comment on table public.visits is
  'One user''s logged experience at a place. Multiple rows per (user, place) are expected.';

drop trigger if exists visits_touch_updated_at on public.visits;
create trigger visits_touch_updated_at
  before update on public.visits
  for each row execute function public.app_touch_updated_at();


create table if not exists public.visit_photos (
  id             uuid primary key default gen_random_uuid(),
  visit_id       uuid not null references public.visits(id) on delete cascade,

  -- Path WITHIN the bucket, e.g. "<user_id>/<visit_id>/<uuid>.jpg" — never a full
  -- URL. Signed URLs expire and the public URL format is a property of the
  -- project, not of the photo; both get regenerated at read time. The path is the
  -- only stable identifier.
  storage_path   text not null,

  width          int,
  height         int,
  sort_order     int not null default 0,

  -- From EXIF. Kept even though the place is already resolved, because it is the
  -- evidence behind that resolution and useful if we ever need to re-resolve.
  captured_at    timestamptz,
  exif_latitude  double precision,
  exif_longitude double precision,

  created_at     timestamptz not null default now(),

  constraint visit_photos_storage_path_not_blank check (btrim(storage_path) <> ''),
  constraint visit_photos_exif_lat_range
    check (exif_latitude  is null or exif_latitude  between  -90 and  90),
  constraint visit_photos_exif_lng_range
    check (exif_longitude is null or exif_longitude between -180 and 180)
);

comment on column public.visit_photos.storage_path is
  'Object path inside the visit-photos bucket. Not a URL.';


-- ----------------------------------------------------------------------------
-- Indexes
-- ----------------------------------------------------------------------------

-- Query: profile timeline —
--   `where user_id = $1 order by visited_at desc limit 50`
create index if not exists visits_user_visited_at_idx
  on public.visits (user_id, visited_at desc);

-- Query: "who else has been here" on a place detail sheet —
--   `where place_id = $1`
create index if not exists visits_place_id_idx
  on public.visits (place_id);

-- Query: global explore feed —
--   `order by visited_at desc limit 50`
create index if not exists visits_visited_at_idx
  on public.visits (visited_at desc);

-- Query: tag filtering on map and feed —
--   `where tags && array['cocktails','date night']`
create index if not exists visits_tags_gin_idx
  on public.visits using gin (tags);

-- Query: photo carousel for a visit —
--   `where visit_id = $1 order by sort_order`
create index if not exists visit_photos_visit_sort_idx
  on public.visit_photos (visit_id, sort_order);
