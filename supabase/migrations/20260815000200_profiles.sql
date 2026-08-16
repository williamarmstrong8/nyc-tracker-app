-- ============================================================================
-- 0200 — profiles
-- ============================================================================
-- One row per auth.users row, created automatically by a trigger on signup.
-- This is the public identity: everything else in the schema points at it rather
-- than at auth.users, so nothing outside this file has to touch the auth schema.
-- ============================================================================

set search_path = public, extensions;

create table if not exists public.profiles (
  id            uuid primary key references auth.users(id) on delete cascade,

  -- NULLABLE ON PURPOSE. Two options were on the table:
  --   (a) generate a placeholder like "user_8f3a21" at signup, or
  --   (b) leave it NULL until the user picks one.
  -- We chose (b). A placeholder is indistinguishable from a real username at the
  -- DB level, so every later query ("is onboarding done?") would need a fragile
  -- prefix check, and any placeholder that leaked into the UI or a shared link
  -- would look like a bug. NULL is an honest sentinel: it means "has not chosen
  -- yet", it is impossible to confuse with a real value, and it maps 1:1 onto
  -- AuthState.needsUsername in the app. The app treats username as REQUIRED —
  -- UsernameSetupView is a hard gate with no skip — so a NULL row is only ever
  -- observable between signup and the end of onboarding.
  username      extensions.citext unique,

  display_name  text,
  avatar_url    text,
  bio           text,

  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),

  -- 3-20 chars, lowercase letters / digits / underscore only.
  --
  -- The `::text` cast is load-bearing. citext makes its comparison and pattern
  -- operators case-insensitive, so a bare `username ~ '^[a-z0-9_]+$'` would
  -- happily accept 'WillNYC'. Casting to text forces a case-SENSITIVE match, so
  -- the constraint actually rejects uppercase and the stored value is guaranteed
  -- lowercase. (The app lowercases before submitting; this is the backstop.)
  constraint profiles_username_format
    check (username is null or username::text ~ '^[a-z0-9_]{3,20}$'),

  constraint profiles_display_name_length
    check (display_name is null or char_length(display_name) between 1 and 50),

  constraint profiles_bio_length
    check (bio is null or char_length(bio) <= 300)
);

comment on table  public.profiles is
  'Public user identity. Mirrors auth.users 1:1 via a signup trigger.';
comment on column public.profiles.username is
  'Case-insensitive handle. NULL until the user completes onboarding; the app treats it as required.';

drop trigger if exists profiles_touch_updated_at on public.profiles;
create trigger profiles_touch_updated_at
  before update on public.profiles
  for each row execute function public.app_touch_updated_at();


-- ----------------------------------------------------------------------------
-- Signup trigger
-- ----------------------------------------------------------------------------
-- Creates the profile row the instant an auth user is created, so the app never
-- has to handle "authenticated but no profile row exists". SECURITY DEFINER
-- because the inserting session is the auth service, not the new user, and RLS
-- on profiles would otherwise block the write.
--
-- Sign in with Apple hands us the user's full name ONLY on the very first
-- authorization. The iOS client stuffs it into user metadata on that first call,
-- so we prefill display_name from it here; on every later sign-in the metadata is
-- absent and display_name simply stays whatever the user set.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, display_name)
  values (
    new.id,
    nullif(
      btrim(coalesce(
        new.raw_user_meta_data ->> 'full_name',
        new.raw_user_meta_data ->> 'name',
        ''
      )),
      ''
    )
  )
  on conflict (id) do nothing;   -- idempotent: re-running the trigger is harmless
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();


-- ----------------------------------------------------------------------------
-- is_username_available(text)
-- ----------------------------------------------------------------------------
-- Backs the debounced availability check in UsernameSetupView.
--
-- Why a function instead of letting the client SELECT profiles directly: a plain
-- select would also work (profiles are world-readable), but this returns a clean
-- boolean, applies the same format rules as the CHECK constraint, and gives us
-- one place to add rate limiting or a reserved-words list later.
--
-- This is a UX affordance, NOT a guarantee. Two users can pass this check
-- simultaneously; the unique index is what actually decides, and the client
-- handles the 23505 unique violation on submit.
create or replace function public.is_username_available(p_username text)
returns boolean
language sql
stable
security definer
set search_path = public, extensions
as $$
  select
    p_username ~ '^[a-z0-9_]{3,20}$'
    and not exists (
      select 1 from public.profiles
      where username = p_username::extensions.citext
    );
$$;

revoke all on function public.is_username_available(text) from public;
grant execute on function public.is_username_available(text) to authenticated;


-- ----------------------------------------------------------------------------
-- Indexes
-- ----------------------------------------------------------------------------

-- Query: user search by handle — `where username::text ilike '%' || $1 || '%'`
-- (friend-finding UI, later task). Trigram GIN makes the leading-wildcard LIKE
-- indexable. Indexed on the ::text projection because gin_trgm_ops is defined
-- for text, not citext.
create index if not exists profiles_username_trgm_idx
  on public.profiles using gin ((username::text) extensions.gin_trgm_ops);

-- Query: user search by real name — same UI, `display_name ilike '%' || $1 || '%'`.
create index if not exists profiles_display_name_trgm_idx
  on public.profiles using gin (display_name extensions.gin_trgm_ops);
