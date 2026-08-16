-- ============================================================================
-- 0100 — Extensions and shared helper functions
-- ============================================================================
-- Everything in this file is infrastructure the later migrations depend on.
-- Run first. All statements are idempotent.
-- ============================================================================

-- Supabase convention: extensions live in their own schema, not public.
create schema if not exists extensions;

-- citext: case-insensitive text. Used for `profiles.username` so that "Will" and
-- "will" cannot both be claimed. Uniqueness falls out of the type, not a lower()
-- index, which keeps the FK/lookup story simple.
create extension if not exists citext with schema extensions;

-- pg_trgm: trigram matching, used for the user-search indexes on
-- profiles.username / profiles.display_name (fuzzy "find my friend" search).
create extension if not exists pg_trgm with schema extensions;

-- Make sure the extension schema is on the search path for everyone, otherwise
-- `citext` is an unknown type in later migrations and in PostgREST queries.
-- (Supabase sets this by default, but we assert it so a fresh/local DB matches.)
do $$
begin
  execute format(
    'alter database %I set search_path to public, extensions',
    current_database()
  );
exception
  -- Not permitted on some managed/pooled connections; the per-role default below
  -- and explicit schema qualification keep things working either way.
  when insufficient_privilege then null;
end $$;

set search_path = public, extensions;


-- ----------------------------------------------------------------------------
-- app_touch_updated_at() — generic BEFORE UPDATE trigger
-- ----------------------------------------------------------------------------
-- Attached to every table with an `updated_at` column so the app never has to
-- remember to set it (and so a malicious client can't lie about it).
create or replace function public.app_touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;


-- ----------------------------------------------------------------------------
-- app_normalize_name(text) — canonical form of a place name
-- ----------------------------------------------------------------------------
-- Feeds `places.normalized_name`, which is half of the fallback dedupe key for
-- places with no MapKit identifier. "Joe's Pizza & Café" and "joes pizza and
-- cafe" must NOT be treated as different venues just because MapKit gave us nil.
--
-- Deliberately NOT using unaccent(): unaccent is STABLE, not IMMUTABLE (its
-- result depends on a dictionary that can be altered), and Postgres refuses
-- STABLE functions inside a GENERATED ALWAYS column. translate() over the Latin-1
-- range covers every diacritic a NYC restaurant name realistically contains.
--
-- Steps: lowercase -> fold diacritics -> "&" to "and" -> drop punctuation ->
--        collapse whitespace -> trim.
create or replace function public.app_normalize_name(p_name text)
returns text
language sql
immutable
strict
parallel safe
as $$
  select btrim(
    regexp_replace(
      regexp_replace(
        replace(
          translate(
            lower(p_name),
            'àáâãäåāăąçćčđďèéêëēĕėęěìíîïĩīĭįıñńňòóôõöøōŏőùúûüũūŭůűųýÿŷšśşžźżčćřľĺţťŕß',
            'aaaaaaaaacccddeeeeeeeeeiiiiiiiiinnnooooooooouuuuuuuuuuyyysssszzzccrllttrs'
          ),
          '&', ' and '
        ),
        '[^a-z0-9 ]', '', 'g'      -- strip punctuation, quotes, emoji, etc.
      ),
      '\s+', ' ', 'g'              -- collapse runs of whitespace
    )
  );
$$;


-- ----------------------------------------------------------------------------
-- app_geohash(lat, lon, precision) — geohash encoder
-- ----------------------------------------------------------------------------
-- Feeds `places.geohash7`, the other half of the fallback dedupe key, and backs
-- proximity lookups without requiring PostGIS.
--
-- Precision 7 is ~153m x 153m at NYC latitudes: tight enough that two different
-- restaurants on the same block don't collapse into one row, loose enough that
-- two phones' GPS readings of the same door land in the same cell. Precision 8
-- (~38m) was too tight — EXIF GPS error alone would split one venue in two.
--
-- Known edge case: cell boundaries. Two readings 5m apart can straddle a cell
-- edge and produce different hashes. This is the *fallback* key only (MapKit ID
-- is primary), and find_or_create_place() checks neighbouring behaviour via an
-- explicit lookup before falling back to the insert, so the blast radius is one
-- duplicate row in a rare case rather than a systematic failure.
--
-- Marked IMMUTABLE: the output is a pure function of its inputs.
create or replace function public.app_geohash(
  p_lat double precision,
  p_lon double precision,
  p_precision int default 7
)
returns text
language plpgsql
immutable
strict
parallel safe
as $$
declare
  base32   constant text := '0123456789bcdefghjkmnpqrstuvwxyz';
  lat_min  double precision := -90;
  lat_max  double precision := 90;
  lon_min  double precision := -180;
  lon_max  double precision := 180;
  is_even  boolean := true;   -- even bits encode longitude, odd bits latitude
  bit_pos  int := 0;
  ch       int := 0;
  mid      double precision;
  result   text := '';
begin
  while length(result) < p_precision loop
    if is_even then
      mid := (lon_min + lon_max) / 2;
      if p_lon > mid then
        ch := ch * 2 + 1;
        lon_min := mid;
      else
        ch := ch * 2;
        lon_max := mid;
      end if;
    else
      mid := (lat_min + lat_max) / 2;
      if p_lat > mid then
        ch := ch * 2 + 1;
        lat_min := mid;
      else
        ch := ch * 2;
        lat_max := mid;
      end if;
    end if;

    is_even := not is_even;

    if bit_pos < 4 then
      bit_pos := bit_pos + 1;
    else
      -- 5 bits accumulated -> one base32 character
      result := result || substr(base32, ch + 1, 1);
      bit_pos := 0;
      ch := 0;
    end if;
  end loop;

  return result;
end;
$$;
