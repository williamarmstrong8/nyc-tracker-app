import SwiftUI

/// Deterministic per-person colour.
///
/// The map needs to answer "whose pin is that" at a glance in "all friends"
/// mode, and it has to keep answering it the same way across launches and
/// between the map, the list and the profile. Hashing the user ID gives a stable
/// colour with no state to store and no assignment step when a friend is added.
///
/// The palette is hand-picked rather than generated from a hue wheel: evenly
/// spaced hues collide badly against a map (several land on road and park
/// colours), and these are chosen to stay legible on both light and dark map
/// styles.
enum FriendPalette {

    static let colors: [Color] = [
        .orange, .purple, .teal, .pink, .indigo,
        .brown, .mint, .cyan, .red, .green
    ]

    static func color(for id: UUID) -> Color {
        colors[stableIndex(for: id, count: colors.count)]
    }

    /// FNV-1a over the UUID bytes.
    ///
    /// Not `hashValue`: Swift seeds `Hasher` per process, so a friend would
    /// change colour on every launch — which is precisely the thing this exists
    /// to prevent.
    private static func stableIndex(for id: UUID, count: Int) -> Int {
        var hash: UInt64 = 0xcbf29ce484222325
        withUnsafeBytes(of: id.uuid) { bytes in
            for byte in bytes {
                hash ^= UInt64(byte)
                hash = hash &* 0x100000001b3
            }
        }
        return Int(hash % UInt64(count))
    }
}

/// Someone's avatar: their uploaded image, or their initials on their palette
/// colour.
///
/// Initials rather than a generic person glyph, because the fallback is the
/// common case early on (few people upload an avatar) and a screen of identical
/// grey silhouettes is unreadable.
struct PersonAvatar: View {
    let person: PersonSummary
    var size: CGFloat = 44
    /// Draws the palette ring used to tie a friend to their map pins. Off by
    /// default — it is meaningful on the map and on friend rows, and noise
    /// everywhere else.
    var showsPaletteRing: Bool = false

    private var tint: Color { FriendPalette.color(for: person.id) }

    var body: some View {
        avatarContent
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay {
                if showsPaletteRing {
                    Circle().strokeBorder(tint, lineWidth: max(2, size * 0.06))
                }
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var avatarContent: some View {
        if let urlString = person.avatarURL,
           let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure:
                    // A dead avatar URL falls back to initials rather than a
                    // broken-image glyph. The bucket is public and the URL is
                    // cache-busted on upload, so this is usually just offline.
                    initials
                case .empty:
                    ZStack {
                        tint.opacity(0.2)
                        ProgressView().controlSize(.mini)
                    }
                @unknown default:
                    initials
                }
            }
        } else {
            initials
        }
    }

    private var initials: some View {
        ZStack {
            LinearGradient(
                colors: [tint.opacity(0.9), tint.opacity(0.45)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Text(initialsText)
                .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
    }

    /// Up to two initials from the display name, else the first character of the
    /// handle, else a neutral dot.
    private var initialsText: String {
        let words = person.bestName
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first }
            .map(String.init)

        if !words.isEmpty { return words.joined().uppercased() }
        if let first = person.username?.first { return String(first).uppercased() }
        return "•"
    }
}

/// Name + handle, stacked. The pairing appears on every social surface, and
/// keeping it in one place is what stops the handle from being sometimes
/// prefixed with `@` and sometimes not.
struct PersonLabel: View {
    let person: PersonSummary
    var nameFont: Font = .body.weight(.semibold)
    var handleFont: Font = .subheadline
    var lineLimit: Int = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(person.bestName)
                .font(nameFont)
                .foregroundStyle(.primary)
                .lineLimit(lineLimit)
            if let handle = person.handle {
                Text(handle)
                    .font(handleFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}
