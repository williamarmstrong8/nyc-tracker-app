-- ============================================================================
-- 0100 — update_place_category()
-- ============================================================================
-- `places.category` is set once — usually from Apple's MapKit classification —
-- and `find_or_create_place()` never overwrites it after that (see
-- 0300_places.sql: every upsert path uses `coalesce(places.category, ...)`).
-- Apple's classification is sometimes wrong (a restaurant tagged as a cafe,
-- etc.), and the app lets a user correct it from the edit screen.
--
-- Places are a deduped, shared table, so the correction is written straight to
-- the canonical row rather than kept as a per-user override — every device and
-- every user logging the same venue sees the fix, not just the one who made it.
-- ============================================================================

set search_path = public, extensions;

create or replace function public.update_place_category(
  p_place_id uuid,
  p_category text
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_caller   uuid := auth.uid();
  v_category text := nullif(btrim(coalesce(p_category, '')), '');
begin
  if v_caller is null then
    raise exception 'update_place_category: authentication required'
      using errcode = '28000';
  end if;

  if v_category is null then
    raise exception 'update_place_category: category is required'
      using errcode = '22023';
  end if;

  update public.places
  set category = v_category
  where id = p_place_id;
end;
$$;

revoke all on function public.update_place_category(uuid, text) from public;
grant execute on function public.update_place_category(uuid, text) to authenticated;
