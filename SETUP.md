# Supabase backend — manual setup

Everything that could be written as code has been. This file covers the parts that
need a browser, an Apple ID, or the Xcode UI.

**The app will not compile until step 3.1 (adding the Swift package) is done, and
will trap at launch with an explanatory message until step 3.3 (the config file)
is done.** Both are deliberate — failing loudly beats a silent misconfiguration.

Do the sections in order.

---

## 1. Supabase dashboard

### 1.1 Create the project

1. Go to <https://supabase.com/dashboard> → **New project**.
2. Name it anything (`nyc-log` is fine). Pick region **East US (North Virginia)** —
   closest to NYC, so latency is lowest for the only users this app has.
3. Save the database password somewhere; you need it in step 1.2.

### 1.2 Run the migrations

Two options. **Use the CLI** — the SQL editor works but you lose migration history,
and the storage migration is easier to re-run when something needs adjusting.

Install and link (from the repo root, `nyc-tracker-app/`):

```bash
brew install supabase/tap/supabase
```

```bash
supabase init
```

`supabase init` creates `supabase/config.toml`. It leaves the existing
`supabase/migrations/` and `supabase/functions/` directories alone — that is why
it wasn't pre-created here. If it asks about generating VS Code settings, say no.

```bash
supabase login
```

```bash
supabase link --project-ref YOUR_PROJECT_REF
```

Your project ref is the subdomain in the project URL — for
`https://abcdefghijklmnop.supabase.co` it's `abcdefghijklmnop`. It's also shown at
**Project Settings → General → Reference ID**. You'll be prompted for the database
password from step 1.1.

```bash
supabase db push
```

That runs all seven migration files in order. Expected output ends with
`Finished supabase db push.`

**If `20260815000700_storage.sql` fails with `must be owner of table objects`:**
your role doesn't own `storage.objects`. Open the dashboard **SQL Editor**, paste
the contents of that one file, and run it there — the SQL editor connects as
`postgres`, which does.

### 1.3 Get the URL and publishable key

**Settings → API Keys.**

- **Project URL** → `https://abcdefghijklmnop.supabase.co`. You need the host only
  (`abcdefghijklmnop.supabase.co`) for step 3.3.
- **Publishable key** → starts with `sb_publishable_`. This is the one that ships
  in the app.
- **Secret key** → starts with `sb_secret_`. Do **not** copy this anywhere near the
  Xcode project. It has `BYPASSRLS` and ignores every policy in
  `supabase/migrations/`.

> **If you're following an older tutorial:** Supabase replaced the legacy JWT keys.
> `anon` is now the **publishable key**; `service_role` is now the **secret key**.
> Projects created recently have **no legacy keys at all** — the legacy tab is
> empty — so instructions pointing at "Project API keys → `anon` `public`" describe
> a section that no longer exists for you.
>
> This renamed the **API keys only**. The **Postgres roles are unchanged** and are
> still `anon`, `authenticated`, and `service_role`. Every `TO authenticated` and
> `revoke ... from anon` in `supabase/migrations/` is correct as written — do not
> "fix" them.

### 1.4 Enable the Apple auth provider (native flow)

**Authentication → Providers → Apple** → toggle **Enable Sign in with Apple**.

The fields here are ambiguous because the same provider page serves two different
flows. For the **native** flow this app uses:

| Field | What to enter |
|---|---|
| **Client IDs** | `projects.nyc-tracker` — your app's **bundle identifier**, nothing else |
| **Secret Key (for OAuth)** | **Leave blank** |
| **Services ID / Team ID / Key ID** | **Leave blank** |

Why: `signInWithIdToken` verifies the identity token Apple issued to your app. The
token's `aud` claim is the bundle ID, and **Client IDs** is the allow-list of
audiences Supabase will accept. The Services ID + secret key exist only for the web
redirect flow (`signInWithOAuth`), which this app does not use.

Click **Save**. If you later add a share extension or a macOS target with a
different bundle ID, add it to **Client IDs** as a comma-separated second entry.

### 1.5 Confirm the storage buckets

**Storage** → you should already see `visit-photos` and `avatars`, created by
`20260815000700_storage.sql`. Click each and confirm under the bucket settings:

- `visit-photos` — Public, 10 MB limit, MIME types `image/jpeg, image/png, image/heic, image/heif, image/webp`
- `avatars` — Public, 2 MB limit, `image/jpeg, image/png, image/webp`

If they're missing, the storage migration didn't run — see the note in 1.2.

### 1.6 Deploy the Edge Function

```bash
supabase functions deploy delete-account
```

**You almost certainly do not need to set any secret by hand.** The Edge runtime
injects the URL and both keys automatically. What it *calls* them is the open
question — the key rename is still rolling out, and the injected names differ
depending on when your project was created and when the function was last
deployed.

The function therefore looks for each key under several names, newest first, and
logs which one it found. That means you don't have to guess up front — deploy,
then read it back.

#### Confirm which variables your deployment actually has

List the names (values are shown only as digests, never in full):

```bash
supabase secrets list
```

Then invoke the function once — the delete-account test in §4.7 will do it — and
read the log line it prints:

```bash
supabase functions logs delete-account
```

You're looking for:

```
delete-account: using secret key from SUPABASE_SERVICE_ROLE_KEY, publishable key from SUPABASE_ANON_KEY
```

The names in that line are the ones your project injects. Only the variable
**names** are logged, never the key values. If you see the new
`SUPABASE_SECRET_KEY` / `SUPABASE_PUBLISHABLE_KEY` names instead, you can trim the
legacy entries from the arrays at the top of `index.ts`.

If neither name is populated, the function fails fast with
`MissingEnvironmentError` naming every variable it looked for, rather than dying
with an opaque 401 inside the admin call. Set one by hand in that case — Supabase
reserves the `SUPABASE_` prefix for secret names, so use the unprefixed form,
which the function also accepts:

```bash
supabase secrets set SECRET_KEY=sb_secret_your_key_here
```

Verify the deploy at **Edge Functions → delete-account**. Leave "Verify JWT" **on**
(the default) — the function re-verifies the caller itself, so this is belt and
braces.

### 1.7 Verify RLS is on

**Database → Tables.** Every table in `public` should show an **RLS enabled**
badge: `profiles`, `places`, `visits`, `visit_photos`, `friendships`,
`recommendations`, `wishlist_items`.

Then check **Advisors → Security Advisor**. It should report no
"RLS disabled in public" errors. Expect it to still flag `SECURITY DEFINER`
functions as a warning — that is intentional here and explained in the migration
comments (`find_or_create_place`, `handle_new_user`, `is_username_available`,
`are_friends`, `friend_ids`).

---

## 2. Apple Developer portal

**Short answer: for the native flow you need the App ID capability and nothing
else. No Services ID. No auth key. No Team ID or Key ID pasted into Supabase.**

A Services ID + private key are required only when Apple has to redirect a browser
back to your server — the web OAuth flow. `ASAuthorizationAppleIDProvider` +
`signInWithIdToken` never leaves the device, so the bundle ID is the whole
identity.

### 2.1 App ID

If you use Xcode's automatic signing (you do — `DEVELOPMENT_TEAM = 73YJKR29VA`),
adding the capability in step 3.2 creates and configures the App ID for you. To do
it by hand or to verify:

1. <https://developer.apple.com/account/resources/identifiers/list>
2. Select the App ID for `projects.nyc-tracker` (or **+** → App IDs → App to create it).
3. Under **Capabilities**, tick **Sign In with Apple**. Leave it on the default
   "Enable as a primary App ID".
4. **Save**.

That's the whole portal-side setup.

---

## 3. Xcode

### 3.1 Add the Swift package

1. **File → Add Package Dependencies…**
2. URL: `https://github.com/supabase/supabase-swift`
3. Dependency Rule: **Up to Next Major Version**, starting at **2.0.0**
4. **Add Package**, then on the product sheet add **`Supabase`** to the
   `nyc-tracker` target.

Only the `Supabase` product is needed — it re-exports `Auth`, `PostgREST`,
`Storage`, `Functions`, and `Realtime`, so the single `import Supabase` in the new
files works even with this project's `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY`
setting. Adding the other products too does no harm.

### 3.2 Add the Sign in with Apple capability

1. Select the project → **nyc-tracker** target → **Signing & Capabilities**.
2. **+ Capability** → **Sign in with Apple**.
3. Confirm "Automatically manage signing" is ticked and the team is
   **73YJKR29VA**. Xcode creates `nyc-tracker.entitlements` and updates the App ID.

Nothing else is needed in the signing pane.

### 3.3 Create and wire up the config file

> **Already have a `Secrets.xcconfig`?** The setting was renamed from
> `SUPABASE_ANON_KEY` to `SUPABASE_PUBLISHABLE_KEY`. Rename it in your existing
> file — the value itself doesn't change. It's gitignored, so it isn't visible from
> here and can't be updated for you. A stale name means the build setting resolves
> to nothing, `Info.plist` keeps the literal `$(SUPABASE_PUBLISHABLE_KEY)`, and the
> app traps at launch.

```bash
cp nyc-tracker/Config/Secrets.example.xcconfig nyc-tracker/Config/Secrets.xcconfig
```

Open `nyc-tracker/Config/Secrets.xcconfig` and fill in the two values from step 1.3:

```
SUPABASE_PROJECT_HOST = abcdefghijklmnop.supabase.co
SUPABASE_PUBLISHABLE_KEY = sb_publishable_...
```

**The host has no `https://` prefix, on purpose.** `.xcconfig` treats `//` as a
comment, so a full URL gets truncated to `https:`. `SupabaseConfig` adds the scheme
back in Swift.

**Check the key's prefix before you paste.** `sb_publishable_` belongs here.
`sb_secret_` never does — it has `BYPASSRLS`, and anything in this file is compiled
into the app bundle where it can be extracted with `strings`. The two values sit
next to each other in the dashboard and differ by one word.

Then wire it into the build:

1. In Xcode, **File → Add Files to "nyc-tracker"…**, select the `Config` folder,
   and add it **without** ticking "Add to targets" (an xcconfig is a build input,
   not a bundled resource).
2. Select the **project** (blue icon, not the target) → **Info** tab →
   **Configurations**.
3. Expand **Debug** and **Release**, and set the dropdown for the `nyc-tracker`
   project to **Secrets** in both.
4. **Product → Clean Build Folder** (⇧⌘K), then build.

`Info.plist` already references `$(SUPABASE_PROJECT_HOST)` and
`$(SUPABASE_PUBLISHABLE_KEY)` — no edit needed there.

To confirm the substitution actually happened, read the **built** Info.plist rather
than the source one (the source always shows the literal `$(...)`):

```bash
plutil -extract SupabasePublishableKey raw -o - "$(ls -dt ~/Library/Developer/Xcode/DerivedData/nyc-tracker-*/Build/Products/Debug-iphonesimulator/nyc-tracker.app | head -1)/Info.plist"
```

That must print a real `sb_publishable_...` value. If it prints the literal
`$(SUPABASE_PUBLISHABLE_KEY)`, the xcconfig isn't wired into the configuration
(step 2 above) or the build wasn't cleaned. If it errors with "does not exist", the
key name in Info.plist doesn't match — check for a stale `SupabaseAnonKey`.

Same check for the host:

```bash
plutil -extract SupabaseProjectHost raw -o - "$(ls -dt ~/Library/Developer/Xcode/DerivedData/nyc-tracker-*/Build/Products/Debug-iphonesimulator/nyc-tracker.app | head -1)/Info.plist"
```

Or just run the app — a wrong setup traps immediately with a message naming the
missing key and the dashboard path to fix it.

### 3.4 Deployment target

Nothing to do. `MKMapItem.identifier` requires iOS 16.4+; this project targets
**iOS 26.5**, so it is unconditionally available and `places.mapkit_id` can be
populated whenever MapKit provides one. The nil-identifier fallback in the schema
exists because MapKit returns nil for dropped pins and unmatched POIs — not because
of OS version.

---

## 4. Verification

Run these in order. Simulator A and B need **different Apple IDs** —
**Settings → Sign in to your iPhone** inside each simulator.

1. **First sign-in creates exactly one profile row.**
   Launch on Simulator A, tap Sign in with Apple, complete the flow.
   Dashboard → **Table Editor → profiles**: exactly **one** row, `id` matching
   **Authentication → Users**, and `username` **NULL**. `display_name` should be
   populated from the Apple credential.
   *(One row, not two — the trigger writes it once and the app never inserts.)*

2. **The username gate blocks progress.**
   You should be on "Choose a username" with no way past it. Check:
   - Swipe down / look for a Cancel button — there is none.
   - Type `ab` → "At least 3 characters", Continue disabled.
   - Type `Will NYC!` → it normalises to `willnyc` as you type.
   - Type a valid name, wait ~500ms → green check, Continue enables.
   - Tap Continue → the map appears. `profiles.username` is now set.

3. **A second account doesn't collide.**
   Simulator B, different Apple ID, sign in. `profiles` now has **two** rows.
   Try to claim the username you used in step 2 → red X and "taken", Continue
   stays disabled.

4. **Session survives a force-quit.**
   Swipe up to kill the app on Simulator A, reopen. You land on the map with no
   sign-in prompt and no visible flash of the sign-in screen.

5. **Session survives delete + reinstall.**
   Delete the app from Simulator A, rebuild and run. Two acceptable outcomes:
   - You land straight on the map — the Keychain item survived the delete (iOS
     keeps Keychain items across app deletion), and the SDK restored it.
   - You see the sign-in screen; tap Sign in with Apple and it completes without
     a new consent prompt.

   Either way, **`profiles` must still have two rows** — the same Apple ID maps to
   the same `auth.users` row, so no third profile is created. That's the actual
   assertion here.

6. **Sign out closes the gate.**
   Profile tab → gear → **Sign out** → confirm. You land on the sign-in screen.
   The map, list, capture flow, and profile are all unreachable.

7. **Delete account removes everything.**
   Sign back in on Simulator A. Before deleting, upload an avatar
   (Settings → tap the avatar) so there's a storage object to clean up.
   Then Settings → **Delete account** → type `DELETE` → confirm.
   Verify in the dashboard:
   - **Authentication → Users** — the user is gone.
   - **Table Editor → profiles** — down to one row (Simulator B's).
   - **Storage → avatars** — the `{user_id}/` folder is gone.
   - The app is back on the sign-in screen.

8. **RLS actually blocks cross-user reads.**
   `recommendations` is the only genuinely private table, so test that one.
   In the **SQL Editor**, insert a row and then read it as the *other* user:

   ```sql
   -- Both ids from Table Editor → profiles. Use any place id, or create one.
   insert into recommendations (sender_id, recipient_id, place_id, message)
   values ('<user-a-uuid>', '<user-b-uuid>', '<place-uuid>', 'go here');

   -- Impersonate a third party (or user B's non-involvement case).
   -- Swap in a uuid that is NEITHER the sender nor the recipient.
   set local role authenticated;
   set local request.jwt.claims = '{"sub":"<unrelated-user-uuid>","role":"authenticated"}';
   select * from recommendations;   -- expect 0 rows
   reset role;
   ```

   Then confirm the recipient *can* see it:

   ```sql
   set local role authenticated;
   set local request.jwt.claims = '{"sub":"<user-b-uuid>","role":"authenticated"}';
   select * from recommendations;   -- expect 1 row
   reset role;
   ```

   Run each block as a single statement batch — `set local` only holds for the
   current transaction.

   Same technique proves the public-by-design reads: as any authenticated uuid,
   `select * from visits` returns everyone's rows. That is correct, not a bug.

---

## 4b. Security notes on the API keys

- **Never paste an `sb_secret_...` value into `Secrets.xcconfig`**, or into any
  file under `nyc-tracker/`. It has `BYPASSRLS` — it ignores every policy in
  `supabase/migrations/` — and everything in the xcconfig is compiled into the app
  bundle, where `strings` recovers it in seconds. Only `sb_publishable_` belongs
  in the client.
- `Secrets.xcconfig` is gitignored. Check it stayed that way after any
  `.gitignore` edit:

  ```bash
  git check-ignore -v nyc-tracker/Config/Secrets.xcconfig
  ```

  Silence with a non-zero exit means it is **not** ignored — fix that before
  committing.
- Cheap pre-commit guard against the mistake that actually matters:

  ```bash
  git diff --cached -U0 | grep -n 'sb_secret_' && echo "BLOCKED: secret key in staged diff" && exit 1
  ```

  Drop that into `.git/hooks/pre-commit` (and `chmod +x` it). It greps for the
  prefix rather than the filename, so it catches the key landing in a README, a
  test fixture, or a pasted log — not just in the xcconfig.
- If a secret key ever does get committed, rotate it in **Settings → API Keys**.
  Removing the commit is not sufficient; assume anything pushed is public.

---

## 5. Things you have to do that I couldn't, and things I guessed

### Couldn't do

- **Anything touching `nyc-tracker.xcodeproj/project.pbxproj`** — adding the Swift
  package, the Sign in with Apple capability, and the xcconfig wiring (steps 3.1,
  3.2, 3.3). Editing the pbxproj while Xcode is open can corrupt the project, per
  the project's own CLAUDE.md. New **source files** needed no pbxproj edit — the
  target uses a `PBXFileSystemSynchronizedRootGroup`, so everything under
  `nyc-tracker/nyc-tracker/` was picked up automatically.
- **Nothing was run or compiled.** No Supabase project exists yet, the Swift
  package isn't added, and there's no Xcode toolchain reachable from this shell —
  so none of the migrations were executed and none of the Swift was type-checked.
  Expect to fix a signature or two on first build; the notes below flag the most
  likely spots.
- **Creating the Supabase project, the Apple provider config, and the App ID
  capability** — all browser/portal work.

### Guessed

- **Bundle identifier `projects.nyc-tracker`** — read out of the pbxproj. If you
  change it, update the Supabase **Client IDs** field to match, or sign-in fails
  with an audience mismatch.
- **Region East US** — a latency guess for a NYC app. Any region works.
- **`supabase-swift` API surface.** Written against the 2.x API
  (`signInWithIdToken`, `authStateChanges`, `FileOptions(contentType:upsert:)`,
  `FunctionInvokeOptions(method:)`). If the storage upload in
  `ProfileService.uploadAvatar` doesn't compile, the older signature is
  `upload(path:file:options:)` — that's the only call I'd expect to have drifted.
- **Rating scale 0–10** on `visits.rating`. The column is unused; the CHECK is a
  placeholder and easy to change before there's data.
- **Geohash precision 7** (~150 m cells) for fallback place matching. Precision 8
  (~38 m) would split one venue across cells on GPS error alone; 6 (~1.2 km) would
  merge different restaurants. 7 is the right trade-off for dense Manhattan blocks,
  but it is a judgement call — see the comment in `20260815000100`.
- **The `DELETE` confirmation phrase.** The spec said "typed confirmation" without
  specifying the word.
- **Which env var names the Edge runtime injects.** The publishable/secret key
  rename is mid-rollout and the injected names vary by project age and deploy date.
  Rather than guess, `delete-account` tries each plausible name and logs the one it
  resolved — see §1.6 for how to read that back and trim the list.

### Deliberately not built (later tasks, per the brief)

- No friendship UI, map filtering, recommendations UI, or explore feed — schema
  and helper functions only.
- **No sync.** The capture flow, map, list, and stats still read and write SwiftData
  exclusively. `visits`, `visit_photos`, and `places` have no client code writing to
  them yet; `find_or_create_place` and the `Remote*` DTOs are the seam for the next
  task.
- `ProfileView`'s stats remain local-only. The only change there was swapping the
  hardcoded "Will Armstrong / @willxnyc" mock for the real profile and replacing
  the disabled "Sign in to sync" button — both of which this task made obsolete.

### One thing to know about the local-first split

Signing in does **not** migrate existing SwiftData rows to Supabase, and signing
out does **not** clear them. A second user signing in on the same device sees the
first user's locally-stored visits. That's a consequence of "keep the existing
local-first behaviour working", which the brief asked for — worth closing when sync
lands, either by scoping the local store per user or by migrating on first sync.
