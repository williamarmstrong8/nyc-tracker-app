// ============================================================================
// delete-account — permanently delete the calling user's account
// ============================================================================
// Apple requires in-app account deletion for App Store approval (Guideline
// 5.1.1(v)), so this is not optional.
//
// Why an Edge Function at all: the client holds the publishable key
// (`sb_publishable_...`), which cannot delete rows from auth.users. Only the
// secret key (`sb_secret_...`, which has BYPASSRLS) can, and that key must never
// ship inside an app binary. So the client calls this function with its own JWT,
// the function proves who the caller is, and then acts on that one user with
// elevated privileges.
//
// Order of operations matters:
//   1. Verify the JWT and resolve the caller's user id.
//   2. Delete storage objects. ON DELETE CASCADE covers Postgres rows but knows
//      nothing about the storage buckets — those objects would be orphaned
//      forever otherwise, still publicly readable via their CDN URLs.
//   3. Delete the auth user last, letting the cascade clear profiles -> visits
//      -> visit_photos -> friendships -> recommendations -> wishlist_items.
//
// Storage first, auth user last, deliberately: if step 2 fails we abort with the
// account intact and the user can retry. If we deleted the auth user first and
// then failed on storage, the caller's identity would be gone and there would be
// no way to work out whose files to clean up.
// ============================================================================

import { createClient } from "jsr:@supabase/supabase-js@2";

const BUCKETS = ["visit-photos", "avatars"] as const;

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

// ---------------------------------------------------------------------------
// Environment resolution
// ---------------------------------------------------------------------------
// Supabase renamed the API keys — `anon` became the publishable key
// (`sb_publishable_...`) and `service_role` became the secret key
// (`sb_secret_...`) — and has been changing which variables the Edge runtime
// auto-injects as that rolls out. Which name is actually populated depends on
// when the project was created and when the function was last deployed, and it
// is not something we can determine from here.
//
// So each key is looked up under every name it plausibly ships as, newest first.
// The legacy `SUPABASE_SERVICE_ROLE_KEY` / `SUPABASE_ANON_KEY` names remain in
// the list because they are still injected for existing projects; drop them once
// `supabase secrets list` shows only the new names.
//
// `SERVICE_ROLE_KEY` / `SECRET_KEY` (no prefix) are last-resort manual overrides:
// Supabase reserves the `SUPABASE_` prefix for secret names, so a hand-set secret
// cannot use one of the prefixed names.

const SECRET_KEY_NAMES = [
  "SUPABASE_SECRET_KEY",
  "SUPABASE_SERVICE_ROLE_KEY",
  "SECRET_KEY",
  "SERVICE_ROLE_KEY",
] as const;

const PUBLISHABLE_KEY_NAMES = [
  "SUPABASE_PUBLISHABLE_KEY",
  "SUPABASE_ANON_KEY",
  "PUBLISHABLE_KEY",
] as const;

/** Thrown when a required environment variable is absent under every known name. */
class MissingEnvironmentError extends Error {
  override name = "MissingEnvironmentError";
  constructor(candidates: readonly string[]) {
    super(`none of these environment variables are set: ${candidates.join(", ")}`);
  }
}

interface ResolvedConfig {
  supabaseUrl: string;
  secretKey: string;
  publishableKey: string;
}

/** First non-empty match, with the variable name it came from. */
function firstPresent(candidates: readonly string[]): { name: string; value: string } {
  for (const name of candidates) {
    const value = Deno.env.get(name);
    if (value && value.length > 0) return { name, value };
  }
  throw new MissingEnvironmentError(candidates);
}

function resolveConfig(): ResolvedConfig {
  const url = firstPresent(["SUPABASE_URL"]);
  const secret = firstPresent(SECRET_KEY_NAMES);
  const publishable = firstPresent(PUBLISHABLE_KEY_NAMES);

  // Logs the variable NAMES that resolved, never the values. This is how you find
  // out which ones your deployment actually has:
  //   supabase functions logs delete-account
  console.log(
    `delete-account: using secret key from ${secret.name}, ` +
      `publishable key from ${publishable.name}`,
  );

  return {
    supabaseUrl: url.value,
    secretKey: secret.value,
    publishableKey: publishable.value,
  };
}

/**
 * Remove every object under `<userId>/` in a bucket.
 *
 * storage.list() is paginated and does not recurse, so we walk the tree: for
 * visit-photos the layout is {user}/{visit}/{file}, two levels deep below the
 * user folder. Entries with no `id` are folders (prefixes); entries with an `id`
 * are real objects.
 */
async function deleteUserFolder(
  // deno-lint-ignore no-explicit-any
  admin: any,
  bucket: string,
  userId: string,
): Promise<number> {
  const filePaths: string[] = [];
  const prefixes: string[] = [userId];

  while (prefixes.length > 0) {
    const prefix = prefixes.pop()!;
    let offset = 0;
    const limit = 100;

    // Paginate — a heavy user can easily have more than 100 photos.
    while (true) {
      const { data, error } = await admin.storage
        .from(bucket)
        .list(prefix, { limit, offset });

      if (error) throw new Error(`list ${bucket}/${prefix}: ${error.message}`);
      if (!data || data.length === 0) break;

      for (const entry of data) {
        const path = `${prefix}/${entry.name}`;
        if (entry.id === null || entry.id === undefined) {
          prefixes.push(path); // folder — descend into it
        } else {
          filePaths.push(path);
        }
      }

      if (data.length < limit) break;
      offset += limit;
    }
  }

  if (filePaths.length === 0) return 0;

  // remove() takes at most 1000 paths per call.
  for (let i = 0; i < filePaths.length; i += 1000) {
    const chunk = filePaths.slice(i, i + 1000);
    const { error } = await admin.storage.from(bucket).remove(chunk);
    if (error) throw new Error(`remove from ${bucket}: ${error.message}`);
  }

  return filePaths.length;
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS_HEADERS });
  }

  if (req.method !== "POST") {
    return json({ error: "Method not allowed" }, 405);
  }

  let config: ResolvedConfig;
  try {
    config = resolveConfig();
  } catch (err) {
    // Named and specific. Without this, a missing secret key surfaces as an
    // opaque 401 from deep inside `admin.auth.admin.deleteUser` that reads like
    // a caller-auth problem rather than a deployment problem.
    console.error(`delete-account: ${(err as Error).name}: ${(err as Error).message}`);
    return json({ error: "Server is not configured for account deletion." }, 500);
  }

  const { supabaseUrl, secretKey, publishableKey } = config;

  // ---- 1. Verify the caller ------------------------------------------------
  // The Authorization header is the caller's own JWT. We resolve it through a
  // NON-privileged client so a forged or expired token simply fails here; the
  // service-role client is never given attacker-controlled input.
  const authHeader = req.headers.get("Authorization") ?? "";
  if (!authHeader.toLowerCase().startsWith("bearer ")) {
    return json({ error: "Missing bearer token." }, 401);
  }

  const callerClient = createClient(supabaseUrl, publishableKey, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data: userData, error: userError } = await callerClient.auth.getUser();
  const user = userData?.user;

  if (userError || !user) {
    return json({ error: "Invalid or expired session." }, 401);
  }

  const userId = user.id;

  // ---- 2 & 3. Elevate and delete ------------------------------------------
  const admin = createClient(supabaseUrl, secretKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  let removedObjects = 0;
  try {
    for (const bucket of BUCKETS) {
      removedObjects += await deleteUserFolder(admin, bucket, userId);
    }
  } catch (err) {
    // Account left intact on purpose — see the header comment.
    console.error(`delete-account: storage cleanup failed for ${userId}:`, err);
    return json(
      { error: "Could not remove your photos. Nothing was deleted — please try again." },
      500,
    );
  }

  const { error: deleteError } = await admin.auth.admin.deleteUser(userId);
  if (deleteError) {
    console.error(`delete-account: auth delete failed for ${userId}:`, deleteError);
    return json({ error: "Could not delete your account. Please try again." }, 500);
  }

  console.log(`delete-account: deleted ${userId} (${removedObjects} storage objects)`);
  return json({ success: true, deletedStorageObjects: removedObjects });
});
