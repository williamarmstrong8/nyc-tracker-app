import Foundation
import Supabase

/// Single shared Supabase client for the whole app.
///
/// Everything that talks to the backend goes through `SupabaseManager.client`.
/// One instance matters more than it looks: the client owns the auth session, its
/// Keychain-backed storage, and the token-refresh timer. A second instance would
/// refresh tokens on its own schedule and the two would fight over the same
/// Keychain item.
///
/// This sits alongside `LocalStore` rather than replacing it. The app is still
/// local-first — SwiftData remains the source of truth for the capture flow, and
/// nothing here writes visits yet. Sync lands in a later task.
enum SupabaseManager {

    static let shared = SupabaseManager.makeClient()

    /// The client. Kept as a computed property so call sites read naturally
    /// (`SupabaseManager.client.auth`) without exposing the initializer.
    static var client: SupabaseClient { shared }

    private static func makeClient() -> SupabaseClient {
        SupabaseClient(
            supabaseURL: SupabaseConfig.url,
            // The SDK's parameter is still `supabaseKey` — that's its API, not ours.
            // The value we pass is now the publishable key.
            supabaseKey: SupabaseConfig.publishableKey,
            options: SupabaseClientOptions(
                db: SupabaseClientOptions.DatabaseOptions(
                    encoder: SupabaseCoding.encoder,
                    decoder: SupabaseCoding.decoder
                ),
                auth: SupabaseClientOptions.AuthOptions(
                    // Session persistence is the default and uses the Keychain on
                    // Apple platforms, which is what lets a session survive both a
                    // force-quit and (usually) an app reinstall.
                    autoRefreshToken: true
                )
            )
        )
    }
}

// MARK: - Date coding

/// Explicit JSON coding for PostgREST payloads.
///
/// Date handling is the single most common source of silent failures against
/// Supabase, so none of it is left to defaults. Postgres `timestamptz` comes back
/// over PostgREST in several shapes depending on the column and the query:
///
///     2026-08-15T22:52:10.123456+00:00   ← 6-digit fractional seconds
///     2026-08-15T22:52:10.123+00:00      ← 3-digit
///     2026-08-15T22:52:10+00:00          ← none at all
///     2026-08-15T22:52:10Z               ← Z instead of an offset
///     2026-08-15                         ← a plain `date` column
///
/// `ISO8601DateFormatter` with a single option set handles exactly one of those
/// and returns nil for the rest, and `JSONDecoder`'s `.iso8601` strategy is that
/// formatter. The failure is quiet and confusing: one row decodes, the next
/// throws `dataCorrupted`. The strategy below tries each shape in turn.
enum SupabaseCoding {

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .useDefaultKeys   // models declare explicit CodingKeys
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)

            if let date = parseDate(raw) { return date }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognised Postgres timestamp: \(raw)"
            )
        }
        return decoder
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .useDefaultKeys
        // Always send fractional-second UTC. Postgres accepts it for both
        // timestamptz and date columns, so one output format covers every case.
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(isoWithFraction.string(from: date))
        }
        return encoder
    }()

    // MARK: Parsing

    private static func parseDate(_ raw: String) -> Date? {
        if let date = isoWithFraction.date(from: raw) { return date }
        if let date = isoPlain.date(from: raw) { return date }
        if let date = fallbackFormatter(for: raw) { return date }
        return nil
    }

    private static let isoWithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Covers the shapes `ISO8601DateFormatter` refuses:
    /// * more than 3 fractional digits (Postgres emits 6 by default, and the
    ///   system formatter rejects them outright rather than truncating)
    /// * a space instead of `T` between date and time
    /// * a bare `date` column with no time component
    private static func fallbackFormatter(for raw: String) -> Date? {
        let formats = [
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX",
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSXXXXX",
            "yyyy-MM-dd'T'HH:mm:ss.SSSSXXXXX",
            "yyyy-MM-dd HH:mm:ss.SSSSSSXXXXX",
            "yyyy-MM-dd HH:mm:ssXXXXX",
            "yyyy-MM-dd"
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }
}
