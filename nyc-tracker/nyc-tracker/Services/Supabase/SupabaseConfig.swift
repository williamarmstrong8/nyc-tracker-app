import Foundation

/// Supabase connection settings, read from the app bundle at launch.
///
/// The values arrive via `nyc-tracker/Secrets.xcconfig` (gitignored) → build settings →
/// `Info.plist` substitution. Nothing is hardcoded here, so the repo stays clean and
/// a different project URL is a one-line change with no recompile of this file.
///
/// ## Why the host and not the full URL
///
/// `.xcconfig` files treat `//` as the start of a comment, so a line like
///
///     SUPABASE_URL = https://abcdefgh.supabase.co
///
/// silently becomes `https:` — the classic way this setup fails with an
/// unhelpful "invalid URL" at runtime. Storing the bare host (`abcdefgh.supabase.co`)
/// sidesteps it entirely; the scheme is added back here where a Swift string literal
/// has no such problem.
enum SupabaseConfig {

    /// Bundle key holding the project host, e.g. `abcdefgh.supabase.co`.
    private static let hostKey = "SupabaseProjectHost"
    /// Bundle key holding the publishable key.
    private static let publishableKeyKey = "SupabasePublishableKey"

    /// Base URL of the Supabase project.
    static let url: URL = {
        guard let host = string(for: hostKey), !host.isEmpty else {
            fatalError(missingMessage(key: hostKey))
        }
        // Tolerate a host that was pasted with a scheme anyway.
        let bare = host
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))

        guard let url = URL(string: "https://\(bare)") else {
            fatalError("SupabaseConfig: '\(host)' is not a usable project host.")
        }
        return url
    }()

    /// Publishable key (`sb_publishable_...`), the successor to the legacy `anon`
    /// JWT key. Safe to ship in the binary — it carries no privilege of its own and
    /// every table is protected by RLS.
    ///
    /// The *secret* key (`sb_secret_...`, formerly `service_role`) must never appear
    /// here: it has BYPASSRLS and anything in the bundle is extractable.
    ///
    /// Note this renamed only the API *keys*. The Postgres roles are still called
    /// `anon`, `authenticated`, and `service_role`, and the RLS policies in
    /// `supabase/migrations/` reference them by those names — unchanged.
    static let publishableKey: String = {
        guard let key = string(for: publishableKeyKey), !key.isEmpty else {
            fatalError(missingMessage(key: publishableKeyKey))
        }

        // An un-filled `Secrets.xcconfig` copied from the example passes the
        // non-empty check above and then fails much later as an opaque 401 from
        // the first request. Shape-check it here so the failure names the cause.
        //
        // `sb_publishable_` is the current format; `eyJ` catches a legacy `anon`
        // JWT, which still works on older projects.
        guard key.hasPrefix("sb_publishable_") || key.hasPrefix("eyJ") else {
            if key.hasPrefix("sb_secret_") {
                fatalError("""
                    SupabaseConfig: SUPABASE_PUBLISHABLE_KEY holds a SECRET key.

                    `sb_secret_...` bypasses RLS and must never ship in a client
                    binary. Replace it with the publishable key
                    (`sb_publishable_...`) from Settings → API Keys, then rotate
                    the secret key you just exposed.
                    """)
            }
            fatalError(missingMessage(key: publishableKeyKey))
        }

        return key
    }()

    /// True when both values are present. Used by diagnostics/previews that would
    /// rather degrade than trap.
    static var isConfigured: Bool {
        guard let host = string(for: hostKey), !host.isEmpty,
              let key = string(for: publishableKeyKey), !key.isEmpty,
              key.hasPrefix("sb_publishable_") || key.hasPrefix("eyJ") else { return false }
        return true
    }

    private static func string(for key: String) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // An unsubstituted build setting comes through literally as "$(NAME)".
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
        return trimmed
    }

    private static func missingMessage(key: String) -> String {
        """
        SupabaseConfig: Info.plist key "\(key)" is missing or empty.

        Fix:
          1. Copy nyc-tracker/Secrets.example.xcconfig to
             nyc-tracker/Secrets.xcconfig
          2. Fill in SUPABASE_PROJECT_HOST and SUPABASE_PUBLISHABLE_KEY.
             Both come from Supabase Dashboard → Settings → API Keys.
             The publishable key starts with "sb_publishable_".
          3. Set it as the configuration file for the nyc-tracker TARGET under
             BOTH Debug and Release (Project → Info → Configurations). Setting
             only Debug builds a Release archive with no credentials, which
             reaches TestFlight and crashes here on launch. Then clean-build.

        See SETUP.md for the full walkthrough.
        """
    }
}
